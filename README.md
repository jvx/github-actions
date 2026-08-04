# Shared GitHub Actions

Reusable GitHub Actions workflows and helper scripts for multiple websites and
applications.

## Purpose

This repository holds shared, secret-free workflow logic that other repositories can call with reusable workflows.

Caller repositories keep their own secrets, target directories, and repo-specific configuration.

## Planned workflows

- checksum drift reports
- PR checks
- staging deploys
- production deploys

## Available workflows

- [Deploy drift report](docs/deploy-drift-report.md): a reusable, report-only
  workflow that compares caller repository files with a remote target and uploads
  sanitized drift report artifacts.
- [Remote log report](docs/remote-log-report.md): a reusable, read-only SSH
  workflow that collects bounded, redacted excerpts from recent remote logs.
- [Rsync deploy dry-run](docs/rsync-deploy-dry-run.md): a reusable, dry-run-only
  workflow that previews rsync upload/update changes and uploads sanitized
  summary artifacts.
- [Rsync deploy](docs/rsync-deploy.md): a reusable real deploy workflow that
  uploads via rsync without `--delete` and writes a bounded deploy report.
- [Immutable Next.js user-systemd deploy](docs/nextjs-systemd-deploy.md): a
  reusable release-directory deployment with shared state, atomic activation,
  bounded health checks, and database-aware rollback.

## Safety model

- No secrets are stored in this repository.
- Production deploy workflows should be version-pinned by caller repositories.
- Report-only workflows should not upload, delete, deploy, or write to remote servers.
- Site-specific protected paths and target directories belong in the caller repository configuration.

## Versioning recommendation

Use `@main` for low-risk reporting workflows during active development.

Use version tags such as `@v1` for production deploy workflows after they are stable.
