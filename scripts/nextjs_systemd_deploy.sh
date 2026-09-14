#!/usr/bin/env bash
# Deploy an already-uploaded release and atomically activate it.
set -Eeuo pipefail

fail() { printf 'deploy: %s\n' "$*" >&2; exit 1; }
require() { [[ -n "${!1:-}" ]] || fail "$1 is required"; }
relative_path() {
  local value=$1 label=$2
  [[ -n "$value" && "$value" != /* && "$value" != "." && "$value" != *$'\n'* ]] || fail "$label must be a non-empty relative path"
  [[ "/$value/" != *"/../"* && "/$value/" != *"/./"* && "$value" != *//* ]] || fail "$label contains an unsafe path component"
}
run_command() {
  local label=$1 command=$2
  printf 'deploy: running %s\n' "$label"
  (cd "$release" && PATH="${DEPLOY_NODE_BIN_DIR}:$PATH" bash -Eeuo pipefail -c "$command")
}
service() { systemctl --user "$@" "$DEPLOY_SYSTEMD_SERVICE"; }
switch_current() {
  local target=$1 temporary="$app_root/.current.$$.tmp"
  rm -f -- "$temporary"
  ln -s "$target" "$temporary"
  if ! mv -Tf -- "$temporary" "$current" 2>/dev/null; then
    # BSD mv lacks -T; this fallback is used only on non-systemd test hosts.
    rm -f -- "$current"
    mv -f -- "$temporary" "$current"
  fi
}
healthcheck() {
  local phase=$1 deadline url
  for url in "$DEPLOY_LOCAL_HEALTHCHECK_URL" "$DEPLOY_PUBLIC_HEALTHCHECK_URL"; do
    deadline=$((SECONDS + DEPLOY_HEALTH_TIMEOUT_SECONDS))
    until curl --fail --silent --show-error --location --max-time 10 --output /dev/null "$url"; do
      (( SECONDS < deadline )) || { printf 'deploy: %s health check timed out\n' "$phase" >&2; return 1; }
      sleep 2
    done
  done
  printf 'deploy: %s health checks passed\n' "$phase"
}

for variable in \
  DEPLOY_APP_ROOT DEPLOY_RELEASE DEPLOY_SYSTEMD_SERVICE DEPLOY_NODE_BIN_DIR \
  DEPLOY_INSTALL_COMMAND DEPLOY_BUILD_COMMAND DEPLOY_MIGRATION_COMMAND \
  DEPLOY_SHARED_ENV_NAME DEPLOY_SHARED_ENV_PATH DEPLOY_DATABASE_RELATIVE_PATH \
  DEPLOY_SHARED_DATABASE_NAME DEPLOY_SHARED_DATABASE_PATH \
  DEPLOY_LOCAL_HEALTHCHECK_URL DEPLOY_PUBLIC_HEALTHCHECK_URL \
  DEPLOY_HEALTH_TIMEOUT_SECONDS DEPLOY_RELEASES_TO_KEEP; do
  require "$variable"
done

[[ "$DEPLOY_APP_ROOT" == /* && "$DEPLOY_APP_ROOT" != "/" ]] || fail "DEPLOY_APP_ROOT must be an absolute non-root path"
[[ "$DEPLOY_RELEASE" == "$DEPLOY_APP_ROOT"/releases/* && "$DEPLOY_RELEASE" != *$'\n'* ]] || fail "DEPLOY_RELEASE must be inside the app releases directory"
[[ "$(dirname "$DEPLOY_RELEASE")" == "${DEPLOY_APP_ROOT%/}/releases" && "$(basename "$DEPLOY_RELEASE")" =~ ^[A-Za-z0-9._-]+$ ]] || fail "DEPLOY_RELEASE must be a direct, safely named child of releases"
[[ "$DEPLOY_SYSTEMD_SERVICE" =~ ^[A-Za-z0-9_.@:-]+$ ]] || fail "DEPLOY_SYSTEMD_SERVICE is invalid"
[[ "$DEPLOY_HEALTH_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "DEPLOY_HEALTH_TIMEOUT_SECONDS must be a positive integer"
[[ "$DEPLOY_RELEASES_TO_KEEP" =~ ^[0-9]+$ ]] && (( DEPLOY_RELEASES_TO_KEEP >= 2 )) || fail "DEPLOY_RELEASES_TO_KEEP must be at least 2"
[[ "$DEPLOY_LOCAL_HEALTHCHECK_URL" =~ ^https?://(localhost|127\.0\.0\.1|\[::1\])([/:]|$) ]] || fail "local health check URL must target loopback"
[[ "$DEPLOY_PUBLIC_HEALTHCHECK_URL" =~ ^https?:// ]] || fail "public health check URL must use HTTP or HTTPS"
relative_path "$DEPLOY_SHARED_ENV_NAME" DEPLOY_SHARED_ENV_NAME
relative_path "$DEPLOY_SHARED_ENV_PATH" DEPLOY_SHARED_ENV_PATH
relative_path "$DEPLOY_DATABASE_RELATIVE_PATH" DEPLOY_DATABASE_RELATIVE_PATH
relative_path "$DEPLOY_SHARED_DATABASE_NAME" DEPLOY_SHARED_DATABASE_NAME
if [[ "$DEPLOY_SHARED_DATABASE_PATH" != "." ]]; then relative_path "$DEPLOY_SHARED_DATABASE_PATH" DEPLOY_SHARED_DATABASE_PATH; fi

app_root=${DEPLOY_APP_ROOT%/}
release=${DEPLOY_RELEASE%/}
current="$app_root/current"
shared="$app_root/shared"
releases="$app_root/releases"
lock_file="$app_root/.deploy.lock"

[[ -d "$app_root" && -d "$shared" && -d "$releases" ]] || fail "app root must already contain shared and releases directories"
[[ -L "$current" ]] || fail "app root must have a bootstrapped current symlink"
[[ -d "$release" ]] || fail "uploaded release does not exist"

exec 9>"$lock_file"
flock -n 9 || fail "another deployment holds the application lock"

old_release=$(readlink -f "$current")
[[ -d "$old_release" && "$old_release" == "$releases"/* ]] || fail "current must resolve to an existing release"
[[ "$old_release" != "$release" ]] || fail "uploaded release is already current"

env_source="$shared/$DEPLOY_SHARED_ENV_NAME"
db_source="$shared/${DEPLOY_SHARED_DATABASE_PATH%/}/$DEPLOY_SHARED_DATABASE_NAME"
[[ -f "$env_source" ]] || fail "shared environment file does not exist"
[[ -f "$db_source" ]] || fail "shared database file does not exist"

mkdir -p "$(dirname "$release/$DEPLOY_SHARED_ENV_PATH")" "$(dirname "$release/$DEPLOY_DATABASE_RELATIVE_PATH")"
ln -s "$env_source" "$release/$DEPLOY_SHARED_ENV_PATH"
ln -s "$db_source" "$release/$DEPLOY_DATABASE_RELATIVE_PATH"

# These intentionally happen while the existing service remains available.
run_command install "$DEPLOY_INSTALL_COMMAND"
run_command build "$DEPLOY_BUILD_COMMAND"

backup_dir="$shared/.deploy-backups"
backup="$backup_dir/database.$(date -u +%Y%m%dT%H%M%SZ).$$.bak"
stopped=0
rollback() {
  local original_status=$?
  trap - ERR INT TERM
  if (( stopped )); then
    printf 'deploy: failure after service stop; rolling back\n' >&2
    service stop || true
    switch_current "$old_release"
    if [[ -f "$backup" ]]; then cp -p -- "$backup" "$db_source"; fi
    if service start && healthcheck rollback; then
      printf 'deploy: rollback completed\n' >&2
    else
      printf 'deploy: rollback health verification failed; manual intervention required\n' >&2
    fi
  fi
  exit "$original_status"
}
trap rollback ERR INT TERM

mkdir -p "$backup_dir"
service stop
stopped=1
cp -p -- "$db_source" "$backup"
run_command migration "$DEPLOY_MIGRATION_COMMAND"
switch_current "$release"
service start
healthcheck deployment
stopped=0
trap - ERR INT TERM

# Keep current and previous regardless of age, then fill remaining retention slots.
kept=2
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  [[ "$candidate" == "$release" || "$candidate" == "$old_release" ]] && continue
  if (( kept < DEPLOY_RELEASES_TO_KEEP )); then
    kept=$((kept + 1))
  else
    rm -rf -- "$candidate"
  fi
done < <(find "$releases" -mindepth 1 -maxdepth 1 -type d -print | sort -r)

printf 'deploy: deployment succeeded\n'
