# Immutable Next.js deployment with user systemd

`nextjs-systemd-deploy.yml` is a reusable deployment workflow for a stateful
Next.js or Node.js application on a VPS. It uploads only Git-tracked caller
content into a unique release, builds without interrupting the current service,
and atomically changes `current` under a deployment lock. A single user systemd
service must own the application's only server process; PM2 and multi-process
orchestration are intentionally outside this workflow.

This is a live deployment workflow. Pin it to a reviewed immutable tag or commit.
Use GitHub environments for approvals and secret scoping.

## Remote bootstrap (required)

The workflow refuses first-time bootstrap. The deployment user must already own
an application root with this shape:

```text
<app-root>/
  current -> <app-root>/releases/<existing-release>
  releases/
    <existing-release>/
  shared/
    runtime.env
    data/
      application.sqlite
```

The environment file and database must be regular files. The workflow links them
into each release at caller-selected relative paths. The user service should use
`WorkingDirectory=<app-root>/current`, start one foreground process, and be
enabled for lingering if it must survive logout. The host needs Bash, `flock`,
Git-compatible tar, base64, curl, SSH, and `systemctl --user`.

Bootstrap the service and verify that its existing release and both health URLs
work before calling this workflow. This workflow does not create systemd units,
initialize databases, or decide that destructive migration recovery is safe.

## Caller example

```yaml
name: Deploy

on:
  workflow_dispatch:

jobs:
  deploy:
    uses: owner/shared-actions/.github/workflows/nextjs-systemd-deploy.yml@v1
    with:
      environment_name: production
      toolkit_repository: owner/shared-actions
      toolkit_ref: 0123456789abcdef0123456789abcdef01234567
      systemd_service: example-app.service
      node_bin_dir: /opt/node/bin
      install_command: npm ci
      build_command: npm run build
      migration_command: npm run migrate
      shared_env_name: runtime.env
      shared_env_path: .env
      shared_database_path: data
      shared_database_name: application.sqlite
      database_relative_path: storage/application.sqlite
      local_healthcheck_url: http://127.0.0.1:3000/health
      public_healthcheck_url: https://app.example.com/health
      health_timeout_seconds: 60
      releases_to_keep: 3
      ssh_port: 22
      artifact_retention_days: 7
    secrets:
      ssh_private_key: ${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}
      ssh_passphrase: ${{ secrets.DEPLOY_SSH_PASSPHRASE }}
      known_hosts: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
      remote_host: ${{ secrets.DEPLOY_HOST }}
      remote_user: ${{ secrets.DEPLOY_USER }}
      remote_app_root: ${{ secrets.DEPLOY_APP_ROOT }}
```

`ssh_passphrase` is optional. `known_hosts` must be generated and reviewed out of
band; the workflow enables strict host-key checking and does not scan or trust a
host key at runtime. Host, user, and application root remain caller secrets.
Commands are caller-controlled shell commands and should not print sensitive
values.

`toolkit_repository` and `toolkit_ref` explicitly identify the checked-out copy
of the remote deployment script. Pin `toolkit_ref` to the same reviewed commit
or immutable tag used by the workflow's `uses:` line; do not infer it from the
caller workflow context.

## Transaction and rollback behavior

1. Strict SSH is configured from caller secrets.
2. A unique release directory is created and populated from `git ls-files`.
3. The remote script validates the pre-bootstrapped layout and obtains `flock`.
4. Shared files are linked; install and build run while the old service stays up.
5. The service is stopped. The shared database is copied to a timestamped backup.
6. Migration runs, `current` changes atomically, and the service starts.
7. Bounded local and public health checks must both pass.
8. Only after success are old releases pruned. Current and immediately previous
   are always protected, and `releases_to_keep` cannot be less than two.

Any error after the stop triggers a fail-closed rollback: stop the service,
restore the prior `current` target, restore the database backup, restart the old
service, and run both health checks again. The workflow still exits failed even
when rollback succeeds. If rollback health also fails, the log requests manual
intervention. Database backups are retained under `shared/.deploy-backups` so the
workflow never automatically discards recovery data.

Migrations must be compatible with a byte-for-byte file backup while the service
is stopped. Do not use this workflow for a remote database server, multiple
database files, or a database whose sidecar/WAL files require a different backup
procedure.

## Reports and concurrency

GitHub concurrency is scoped to caller repository and environment, with
`cancel-in-progress: false`. The remote `flock` additionally serializes callers
that share an application root. The job has minimal `contents: read` permission
and a 60-minute timeout.

The always-run artifact and job summary contain only success/failure and generic
policy text. They omit host, user, paths, commands, and endpoint values. Normal
command output remains in the protected Actions job log; callers should ensure
build and migration tools do not print secrets.
