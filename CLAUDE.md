# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Start here

Read these first — they are the source of truth for what this repo is and why
it is shaped the way it is. Do not restate their contents below; only additions
that don't belong in either doc live here.

- @README.md — what runs, setup, everyday operations.
- @DESIGN.md — architecture and the reasoning behind every design choice.

There is no application code and no build step. The "code" is: shell drivers in
`bin/`, Compose service definitions in `compose/`, a resticprofile config in
`backup/`, systemd units in `systemd/`, and the bats suite in `test/`.

## Invariants to preserve when editing

These are load-bearing. Changing them changes the design — see DESIGN.md before
you do.

- **Base compose files stay hardware-free.** Anything environment-specific
  (dongle `devices:`, `network_mode: host`, `privileged`, host D-Bus/udev
  mounts) belongs in `compose/hardware.yaml`, never in `compose/<app>.yaml`. The
  base stack must stay runnable in CI with no overlay.
- **`hl_render_map`'s fail-closed contract** (return 0 = written, 2 = last-good
  preserved, 3 = hard stop with no fallback) is all-or-nothing per file. Preserve
  it exactly when touching `bin/lib.sh`.
- **`bin/apply` converges unconditionally.** `docker compose up -d` runs every
  time; the git/env change flags are for logging only. Don't reintroduce gating
  that would skip convergence — it's what makes the stack self-healing.
- **`bin/restore` restarts only on success** and always writes the pre-restore
  `tar | zstd` rollback tarball first. The profile's `<app>.restore` sections
  stay hook-free (bin/restore owns the stop/start) to avoid a double stop/start.
- **No hardcoded paths.** Host paths come from the overridable `${HL_*}`
  variables in `bin/lib.sh` (`HL_REPO_ROOT`, `HL_ENV_DIR`, `HL_DATA_ROOT`,
  `HL_ROLLBACK_DIR`, `HL_SYSTEMD_DIR`). Toolchain location comes from `mise` —
  invoke via `mise exec`, never a shim path. `hl_app_datadir` is the single place
  that maps an app to its data dir; extend it there when adding a stateful app.

## Conventions in `bin/*` shell scripts

- All scripts source `bin/lib.sh` and start with `set -Eeuo pipefail`.
- Helpers are prefixed `hl_`; logging (`hl_info` / `hl_warn` / `hl_err`) goes to
  stderr so stdout stays clean.
- `hl_compose()` is the single choke point for the compose invocation
  (`docker compose --project-directory "${HL_REPO_ROOT}" "$@"`) — use it rather
  than calling `docker compose` directly, so every script targets the same
  project regardless of cwd.

## Testing (`test/`)

The bats suite runs the **real** tools (docker, compose, git, zstd,
restic/resticprofile, mise). Only `bws` and `systemctl` are stubbed
(`test/helpers/stubs/`): `bws` because it would otherwise need live production
credentials, `systemctl` because `bootstrap.bats` must not mutate the shared
runner's real init system. Hold any new stub to that same bar — stub only what
is unsafe or impossible to run for real, never for convenience, and delete tests
that would only exercise a stub's own behavior.

- Tests point the `${HL_*}` paths at per-test temp dirs and run the **base**
  stack (no `COMPOSE_FILE` overlay), so nothing touches real `/opt` or `/etc`.
- `test/lib.bats` needs no Docker and runs locally:
  `mise exec -- bats test/lib.bats`. `apply.bats`, `backup.bats`, `restore.bats`,
  `bootstrap.bats` need real Docker/systemd and run only in GitHub Actions
  (`.github/workflows/test.yaml`). This dev sandbox has no Docker-in-Docker, so
  the local ceiling for those files is a clean `bash -n` + shellcheck pass.
- shellcheck's bats-mode check (SC2314) is real: `! cmd` inside a `@test` does
  not fail the test — use `run ! cmd`.

## Linting and CI

Validation is entirely linting. Run it locally via pre-commit (also enforced in
CI through `.github/workflows/lint.yaml`):

```bash
pre-commit install          # one-time; enables commitlint on commit-msg
pre-commit run --all-files
```

Hooks (`.pre-commit-config.yaml`): generic hygiene (large files, private keys,
EOF/whitespace, line endings), texthooks (smartquotes/ligatures/spaces),
yamllint (`--strict`), shellcheck, markdownlint-cli2, commitlint, checkov, and
gitleaks. CI additionally lints GitHub Actions workflows (incl. zizmor) and the
Renovate config.

- **markdownlint runs with `--fix`.** It rewrites Markdown in place and will
  mangle prose that looks like list markup (e.g. a line starting with `+` or
  `-`). Surround lists with blank lines and give every fenced block a language.
- **Commits are Conventional Commits.** Enforced scopes are `dev-tools`,
  `github-actions`, `release`, `renovate`, or empty (see `commitlint.config.js`).
  Header max length is 120.
- New GitHub Actions steps that need the repo + toolchain should use
  `ppat/homelab-ops-actions/actions/setup-repository-tools` (checks out to
  `./current`, runs `mise install` there) rather than separate
  `actions/checkout` + mise steps, matching the org convention. Remember
  `working-directory: current` on subsequent steps.

## Toolchain

Versions are pinned in `mise.toml` (`mise install`), covering both Pi runtime
CLIs (`bws`, `restic`, `resticprofile`, `zstd`, `jq`) and lint tools as one
superset installed everywhere. Renovate updates `image:` tags under `compose/**`
and tool versions in `mise.toml` / GitHub Actions; merging the PR is the human
gate for every update.
