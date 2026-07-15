# Design

This document explains *why* `homelab-pi` is built the way it is. For what runs
and how to operate it, see [README.md](README.md).

## The problem

Most of the homelab runs on a Kubernetes cluster (Flux + Renovate + Longhorn).
A handful of apps can't: they own USB radios (Zigbee, Z-Wave) or need direct
host Bluetooth (BlueZ/BLE), so they must run on a specific physical Raspberry
Pi. This repo brings the same discipline the cluster enjoys — git as the source
of truth, Renovate-driven updates, automated backups, no manual host state — to
that one host.

There is no application code and no build step. The "code" is configuration and
glue: Compose service definitions, a resticprofile config, four shell drivers,
and systemd units.

## Guiding principle: decomplect "what" from "where"

The central design tension is between two kinds of fact:

- **What the stack is** — images, ports, volume mount points, how env is wired.
  This is portable: it is identical on the Pi and in CI.
- **Where this Pi puts it** — the USB dongle by-id paths, host data directories,
  whether host networking/privileged is needed, where the toolchain lives.
  This is environment-specific.

Keeping these separate — each fact with exactly one home — is what keeps the
system simple. When the two are entangled, every environment-specific value has
to be hardcoded in one place and then *backed out* somewhere else (e.g. a test
override that strips hardware fields the base files shouldn't have had). The
design below gives each concern a single home instead.

| Concern | Home |
| --- | --- |
| Service definitions (portable) | `compose/*.yaml` (hardware-free, CI-runnable) |
| Hardware (dongles, host net, privileged, D-Bus, udev) | `compose/hardware.yaml` (additive, Pi-only) |
| Host paths (repo, env, data, rollback, systemd) | `${HL_*}` variables in `bin/lib.sh` |
| Secret *values* | Bitwarden Secrets Manager (never in the repo) |
| Toolchain location | `mise` (never a hardcoded path) |

## Compose: one project, base + overlay

`compose.yaml` uses top-level `include:` (Compose ≥ 2.20) to merge one file per
app from `compose/*.yaml` into a single project. `docker compose up -d` from the
repo root brings up the whole stack; `docker compose stop zigbee2mqtt` still
targets one service. Files organize the codebase; Compose provides per-service
lifecycle.

The base `compose/*.yaml` files are **hardware-free**: no dongle `devices:`, no
`network_mode: host`, no `privileged`, no host D-Bus mount. They form a complete,
runnable stack on their own — which is exactly what CI runs.

`compose/hardware.yaml` is an **additive overlay** carrying every
environment-specific hardware fact. On the Pi it is layered on via
`COMPOSE_FILE=compose.yaml:compose/hardware.yaml` (set by `bin/bootstrap` and the
systemd units). Compose merges the overlay into the same-named services: list
fields (`devices`, `volumes`) append and scalars (`network_mode`, `privileged`)
set. In CI, `COMPOSE_FILE` is simply not set, so the overlay never applies.

This makes the environment-specific file the small, obviously-Pi-only overlay,
rather than a CI copy that has to track the base. Host paths inside the base
files are `${HL_ENV_DIR:-/etc/homelab-pi}` / `${HL_DATA_ROOT:-/opt}`
interpolations, so tests point them at temp dirs without editing anything.

## Secrets: references, never values

The repo holds **references, not secret values**. Each map file pairs an env var
with a Bitwarden Secrets Manager UUID (UUIDs are not sensitive, so the maps are
safe to commit):

- `compose/env/<app>.secrets.map` — per-app secrets.
- `backup/restic.secrets.map` — restic repo password and S3 endpoint/bucket/keys.

At runtime the drivers resolve each UUID via the `bws` CLI and write
`${HL_ENV_DIR}/<name>.env` atomically. Consumers then load that file: Compose via
`env_file:`; for restic, `bin/backup` / `bin/restore` source-and-export
`restic.env` before invoking resticprofile (see below).

Every environment-specific value — S3 endpoint/bucket, MQTT host/user/password,
app secrets — comes from bws. The repo carries no environment-specific config.
The **one** value that cannot come from bws is `BWS_ACCESS_TOKEN` itself
(chicken-and-egg): it is the sole host-provided input, prompted once by
`bin/bootstrap` and stored at `${HL_ENV_DIR}/bws.env` (0600).

### Fail-closed rendering

`hl_render_map` (in `bin/lib.sh`) renders one map to one env file with
**all-or-nothing-per-file** semantics:

- All secrets resolve → write the env file atomically (return 0).
- Any secret fails to resolve, but a prior env file exists → leave the last-good
  file untouched and continue (return 2). A bws outage never reverts a running
  app to a broken or partial env.
- Any secret fails and there is no prior env to fall back on → hard stop
  (return 3).

Secret **rotation** propagates naturally: a changed value in bws rewrites the env
file on the next apply, which triggers exactly the affected container recreate.

## `bin/apply`: the pull-based reconciler

`bin/apply` is this repo's answer to "Flux for Compose". Each run:

1. `git pull --ff-only` the repo into place.
2. Render every app's env file from bws (fail-closed, per the above).
3. `docker compose pull` to fetch any image tags Renovate merged.
4. **Always** `docker compose up -d --remove-orphans` to converge actual state to
   desired state.

Convergence is unconditional by design: `compose up -d` is a fast no-op when
nothing changed, and running it every time is what makes the system
self-healing — a container that was manually stopped or removed comes back on the
next run. Change flags (git HEAD moved, env hash changed) are computed only to
log *what* triggered a run, never to gate *whether* convergence happens.

It runs daily via `systemd/homelab-apply.timer` and is safe to run by hand
(`sudo systemctl start homelab-apply`, or `./bin/apply`) for on-demand updates.

## `bin/backup`: state ownership delegated to resticprofile

`bin/backup` resolves restic/S3 creds from bws into `${HL_ENV_DIR}/restic.env`
(fail-closed), then `set -a; source restic.env; set +a` to export them and
invokes `resticprofile full-backup.backup`. The source-and-export is load-bearing,
not incidental: `backup/profiles.yaml` sets `repository: '${RESTIC_S3_ROOT}/…'`,
and resticprofile expands that `${VAR}` from its **own process environment**
during config parsing. A profile-level `env-file:` directive does not help here —
it is loaded too late, reaching only the restic subprocess, so with it alone
`${RESTIC_S3_ROOT}` expands empty and restic looks for a repository at `/<app>`.
resticprofile (`backup/profiles.yaml`) owns everything else about the snapshots:

- One restic repository per data directory, under a shared S3 prefix.
- Retention (the `keep-*` ladder) and pruning.
- Per-app quiesce hooks (`run-before` / `run-after` / `run-finally`) that stop
  the service for the duration of its own snapshot and guarantee a restart even
  if the snapshot fails, giving each snapshot crash consistency.

## `bin/restore`: separate from the backup quiesce hooks

Restore is deliberately not driven by resticprofile hooks. The profile's
`<app>.restore` sections have no `run-before`/`run-after`, specifically to avoid
a double stop/start, because `bin/restore` owns the whole sequence itself:

1. Validate the app is known and stateful (stateless apps are refused).
2. Resolve restic creds from bws *before* touching anything, so a creds failure
   aborts before the service is stopped.
3. Stop the service.
4. Capture a pre-restore rollback tarball of the current data dir to
   `${HL_ROLLBACK_DIR}/<app>-pre-restore-<ts>.tar.zst` via `tar | zstd`. This is
   the "undo the restore itself" escape hatch — for a wrong snapshot or a partial
   restore — and has no native resticprofile equivalent.
5. `resticprofile <app>.restore --delete --target /`. `--delete` makes this a
   clean replace (restic's default is a merge that would leave stray files
   behind); the rollback tarball is what makes a clean replace safe to attempt.
6. Restart the service **only on success**. A failed restore leaves the service
   stopped and prints the rollback path, rather than racing an automatic restart
   onto partially-restored data.

## Invocation: everything through mise

The toolchain (`bws`, `restic`, `resticprofile`, `zstd`, `jq`, and the linters)
is pinned in `mise.toml`. Nothing hardcodes where mise installs its shims.
Instead, the outermost process is always `mise exec`, and child processes inherit
mise's PATH:

- systemd units run `ExecStart=/usr/bin/env mise exec -- bin/apply` (resp.
  `bin/backup`) with `WorkingDirectory=/opt/homelab-pi` (which contains
  `mise.toml`). `/usr/bin/env` is the only fixed path — universal, not
  environment-specific.
- `bin/bootstrap` runs its first converge as `mise exec -- bin/apply`.

Because `mise exec` resolves the toolchain from the `mise.toml` in the working
directory, the drivers never need a shim path and the units never need a
hand-maintained `PATH=`.

## Pull-only egress

The Pi accepts no inbound connections. It reaches **out** to exactly three
destinations: the git remote, the Bitwarden API, and the S3 endpoint. Any
firewall or VLAN change must preserve egress to those three and nothing needs to
reach in.
