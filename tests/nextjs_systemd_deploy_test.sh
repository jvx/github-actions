#!/usr/bin/env bash
set -Eeuo pipefail

script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/nextjs_systemd_deploy.sh
tmp=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT
fake_bin="$tmp/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -eu
[[ "$1" == "--user" ]]
printf '%s\n' "$2" >> "$TEST_SERVICE_LOG"
FAKE
cat > "$fake_bin/flock" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat > "$fake_bin/readlink" <<'FAKE'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == -f ]]; then
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$2"
else
  /usr/bin/readlink "$@"
fi
FAKE
cat > "$fake_bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -eu
if [[ "${TEST_FAIL_NEW:-0}" == 1 && "$(basename "$(readlink -f "$TEST_ROOT/current")")" == new ]]; then
  exit 22
fi
exit 0
FAKE
chmod +x "$fake_bin"/* "$script"

setup_app() {
  local root=$1
  mkdir -p "$root/releases/old" "$root/releases/new" "$root/shared/db"
  printf 'ENV=test\n' > "$root/shared/runtime.env"
  printf 'original\n' > "$root/shared/db/app.sqlite"
  ln -s "$root/releases/old" "$root/current"
  : > "$root/service.log"
}

deploy() {
  local root=$1
  env \
    PATH="$fake_bin:$PATH" TEST_ROOT="$root" TEST_SERVICE_LOG="$root/service.log" \
    TEST_FAIL_NEW="${TEST_FAIL_NEW:-0}" \
    DEPLOY_APP_ROOT="$root" DEPLOY_RELEASE="$root/releases/new" \
    DEPLOY_SYSTEMD_SERVICE=example.service DEPLOY_NODE_BIN_DIR="$fake_bin" \
    DEPLOY_INSTALL_COMMAND='test "$(basename "$(readlink -f "$TEST_ROOT/current")")" = old' \
    DEPLOY_BUILD_COMMAND='test "$(basename "$(readlink -f "$TEST_ROOT/current")")" = old' \
    DEPLOY_MIGRATION_COMMAND='printf "migrated\n" > data/app.sqlite' \
    DEPLOY_SHARED_ENV_NAME=runtime.env DEPLOY_SHARED_ENV_PATH=.env \
    DEPLOY_DATABASE_RELATIVE_PATH=data/app.sqlite \
    DEPLOY_SHARED_DATABASE_NAME=app.sqlite DEPLOY_SHARED_DATABASE_PATH=db \
    DEPLOY_LOCAL_HEALTHCHECK_URL=http://127.0.0.1:3000/health \
    DEPLOY_PUBLIC_HEALTHCHECK_URL=https://example.invalid/health \
    DEPLOY_HEALTH_TIMEOUT_SECONDS=1 DEPLOY_RELEASES_TO_KEEP="${KEEP:-2}" \
    "$script"
}

# Validation/refusal: a deployment cannot bootstrap an uninitialized application.
validation_root="$tmp/validation"
setup_app "$validation_root"
rm "$validation_root/current"
if deploy "$validation_root" >"$tmp/validation.out" 2>&1; then
  echo "FAIL: missing current symlink was accepted" >&2
  exit 1
fi
grep -q 'bootstrapped current symlink' "$tmp/validation.out"
printf 'ok - validation refuses an unbootstrapped app root\n'

# Success: build occurs on the inactive release and current switches afterward.
success_root="$tmp/success"
setup_app "$success_root"
KEEP=2
if ! deploy "$success_root" >"$tmp/success.out" 2>&1; then
  cat "$tmp/success.out" >&2
  exit 1
fi
[[ "$(readlink -f "$success_root/current")" == "$success_root/releases/new" ]]
[[ "$(cat "$success_root/shared/db/app.sqlite")" == migrated ]]
[[ "$(tr '\n' ' ' < "$success_root/service.log")" == 'stop start ' ]]
printf 'ok - successful deployment atomically switches the release\n'

# Health failure: database and current are both restored, then rollback is checked.
rollback_root="$tmp/rollback"
setup_app "$rollback_root"
if TEST_FAIL_NEW=1 deploy "$rollback_root" >"$tmp/rollback.out" 2>&1; then
  echo "FAIL: failed health check reported success" >&2
  exit 1
fi
[[ "$(readlink -f "$rollback_root/current")" == "$rollback_root/releases/old" ]]
[[ "$(cat "$rollback_root/shared/db/app.sqlite")" == original ]]
[[ "$(tr '\n' ' ' < "$rollback_root/service.log")" == 'stop start stop start ' ]]
grep -q 'rollback completed' "$tmp/rollback.out"
printf 'ok - health failure restores the prior release and database\n'

# Retention: current and immediately previous survive even when older by name.
retention_root="$tmp/retention"
setup_app "$retention_root"
mkdir -p "$retention_root/releases/zzz-extra" "$retention_root/releases/aaa-extra"
KEEP=2 deploy "$retention_root" >"$tmp/retention.out" 2>&1
[[ -d "$retention_root/releases/new" && -d "$retention_root/releases/old" ]]
[[ ! -e "$retention_root/releases/zzz-extra" && ! -e "$retention_root/releases/aaa-extra" ]]
printf 'ok - retention always protects current and previous releases\n'
