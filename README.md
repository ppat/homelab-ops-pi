# homelab-pi

GitOps management for the Docker Compose apps that must run on a physical
Raspberry Pi because they own USB radios (Zigbee, Z-Wave) or need host Bluetooth
(BLE). Everything on the k8s cluster is handled by Flux + Renovate + Longhorn;
this repo brings the same discipline — git as source of truth, Renovate-driven
updates, automated backups — to the compose stack that can't live on k8s.

## What runs here

| App | Why on the Pi | State |
| ----- | --------------- | ------- |
| zigbee2mqtt | Sonoff Zigbee dongle | `/opt/zigbee2mqtt/data` (SQLite) |
| zwave-js-ui | Zooz Z-Wave stick | `/opt/zwave-js/data` |
| theengsgateway | host BlueZ / BLE scan | stateless |

## Design in one paragraph

One Compose **project** assembled from one file per app via top-level
`include:` (Compose ≥ 2.20). `docker compose up -d` from the repo root brings up
the whole stack; `docker compose stop zigbee2mqtt` still targets one service —
so files organize the codebase while Compose provides per-service lifecycle. A
daily **pull-based applier** (`bin/apply`, systemd timer) does `git pull` →
render env files from Bitwarden Secrets Manager → `compose pull` →
`compose up -d` only if something changed. Daily **backups** (`bin/backup` →
resticprofile) push each data dir to its own restic repo under a shared S3
prefix, quiescing each service for the duration of its own snapshot. Renovate
opens PRs for image and tool updates; merge is the human gate.

## Layout

```
compose.yaml              # include: the per-app files
compose/*.yaml            # one file per app
compose/env/*.secrets.map # ENV_VAR=<bws-uuid>, resolved at apply time
backup/profiles.yaml      # resticprofile: per-app repo, retention, quiesce
bin/apply, bin/backup     # drivers; bin/lib.sh shared helpers
systemd/*.{service,timer} # daily apply + daily backup
mise.toml                 # pinned tool chain (runtime + linters)
```

## Secrets model

The repo holds **references, not values**. Secrets maps
(`compose/env/<app>.secrets.map` for apps, `backup/restic.secrets.map` for
restic/S3) map each env var to a Bitwarden Secrets Manager secret UUID (UUIDs
are not sensitive). At runtime the applier and backup driver resolve each via
`bws`, write `/etc/homelab-pi/<name>.env` atomically, and the consumer loads it
(`env_file:` for compose, `EnvironmentFile=` for the backup unit).

All environment-specific values — including S3 endpoint/bucket, MQTT
host/user/password, and app secrets — come from bws. The repo carries no
environment-specific config. The **one** value that cannot come from bws is
`BWS_ACCESS_TOKEN` itself (chicken-and-egg); it is the sole host-provided input,
prompted once by `bin/bootstrap`, stored at `/etc/homelab-pi/bws.env` (0600).

- **Rotation propagates on apply:** a changed value in bws rewrites the env and
  triggers exactly the affected recreate.
- **Fail-closed per file:** if bws is unreachable or a secret is empty, that
  env file is left at last-good and the run continues. The only hard stop is
  first-run with no prior env to fall back on.

## Setup

### Phase 1 — bws project setup (one-time, off-host)

Create the secrets in Bitwarden Secrets Manager and record their UUIDs in the
maps, then commit:

- App secrets → `compose/env/*.secrets.map`
- restic/S3 (endpoint+bucket as `RESTIC_S3_ROOT`, keys, repo password) →
  `backup/restic.secrets.map`

This is data entry in bws plus pasting UUIDs; it is not a host step and cannot
be scripted (the script can't invent secret UUIDs).

### Phase 2 — host bootstrap (single command)

Prereqs on the Pi: Docker with the Compose v2 plugin (**≥ 2.20**) and `mise`.

```bash
sudo git clone <repo-url> /opt/homelab-pi
cd /opt/homelab-pi
sudo ./bin/bootstrap
```

`bin/bootstrap` prompts for `BWS_ACCESS_TOKEN` only if it isn't already present,
then does everything else with no further input: installs the toolchain via
mise, creates the rollback dir, installs and enables the timers, and runs the
first apply + first backup so the system is live on exit. Idempotent.

## Everyday operations

- **On-demand update:** `sudo systemctl start homelab-apply` (or run
  `./bin/apply` directly). Idempotent; only converges on real change.
- **One service:** `docker compose stop|start|logs zigbee2mqtt`.
- **Add an app:** drop `compose/<app>.yaml`, add it to `include:` in
  `compose.yaml`, add `compose/env/<app>.secrets.map` (may be empty), and — if
  stateful — a profile in `backup/profiles.yaml`. No script/unit changes.
- **Restore:** `sudo ./bin/restore <app> [snapshot-id]`. Stops the service,
  writes a timestamped rollback tarball to `/opt/backups/homelab-pi/` (so you
  can undo the restore itself), restores from restic (`latest` unless you pass a
  snapshot id), then restarts the service. Refuses stateless apps. To undo a
  restore, extract the rollback artifact back into the data dir's parent while
  the service is stopped.

## Updates & linting

Renovate manages `image:` tags across `compose/**` and tool versions in
`mise.toml`; both arrive as PRs. CI (`.github/workflows/lint.yml`) runs
shellcheck, shfmt, yamllint, and gitleaks on every PR; run the same locally with
`pre-commit install` then `pre-commit run --all-files`. Compose `include:`
validation runs in the local pre-commit hook (needs the docker daemon), skipped
in CI.

## Firewall note (IoT VLAN)

The Pi is pull-based by design: it reaches **out** to the git remote, Bitwarden
API, and the S3 endpoint. Nothing reaches into the IoT VLAN. Ensure egress to
those three destinations is permitted.
