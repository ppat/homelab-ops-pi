# homelab-pi

GitOps for the Docker Compose apps that must run on a physical Raspberry Pi
because they own USB radios (Zigbee, Z-Wave) or need host Bluetooth (BLE).
Everything else in the homelab runs on Kubernetes (Flux + Renovate + Longhorn);
this repo brings the same discipline — git as source of truth, Renovate-driven
updates, automated backups, no manual host state — to the one host that can't be
a cluster node.

For the architecture and the reasoning behind it, see [DESIGN.md](DESIGN.md).

## What runs here

| App | Why on the Pi | State |
| --- | --- | --- |
| zigbee2mqtt | Sonoff Zigbee dongle | `/opt/zigbee2mqtt/data` (SQLite) |
| zwave-js-ui | Zooz Z-Wave stick | `/opt/zwave-js/data` |
| theengsgateway | host BlueZ / BLE scan | stateless |

## How it works

- One Compose project is assembled from one hardware-free file per app
  (`compose/*.yaml`) via top-level `include:`. On the Pi, a small overlay
  (`compose/hardware.yaml`) adds the dongle passthrough, host networking, and
  D-Bus access.
- A daily pull-based applier (`bin/apply`) does `git pull` → render env files
  from Bitwarden Secrets Manager → `compose pull` → `compose up -d`. It is
  idempotent and self-healing: every run reconverges the stack.
- Daily backups (`bin/backup` → resticprofile) push each data dir to its own
  restic repo under a shared S3 prefix, quiescing each service around its own
  snapshot.
- Renovate opens PRs for image and tool updates; merging is the human gate.

## Layout

```text
compose.yaml               # include: the per-app files (base stack)
compose/*.yaml             # one hardware-free file per app
compose/hardware.yaml      # Pi-only overlay: dongles, host net, D-Bus, udev
compose/env/*.secrets.map  # ENV_VAR=<bws-uuid>, resolved at apply time
backup/profiles.yaml       # resticprofile: per-app repo, retention, quiesce
backup/restic.secrets.map  # restic/S3 creds as ENV_VAR=<bws-uuid>
bin/apply, bin/backup      # daily drivers
bin/restore, bin/bootstrap # on-demand restore; one-shot host setup
bin/lib.sh                 # shared helpers + overridable ${HL_*} paths
systemd/*.{service,timer}  # daily apply + daily backup
mise.toml                  # pinned toolchain (runtime CLIs + linters)
```

## Secrets

The repo holds **references, not values**. Each map file pairs an env var with a
Bitwarden Secrets Manager secret UUID (UUIDs aren't sensitive, so the maps are
committed). At runtime `bin/apply` / `bin/backup` resolve each via `bws` and
write `/etc/homelab-pi/<name>.env` atomically. Compose loads its file via
`env_file:`; `bin/backup` / `bin/restore` source-and-export `restic.env` before
invoking resticprofile. Every environment-specific value — S3
endpoint/bucket, MQTT credentials, app secrets — comes from bws; the repo carries
no environment-specific config.

The one value that can't come from bws is `BWS_ACCESS_TOKEN` itself. It is the
sole host-provided input, prompted once by `bin/bootstrap` and stored at
`/etc/homelab-pi/bws.env` (0600). See `bws.env.example`.

If bws is unreachable during a run, the affected env file is left at its last-good
value and the run continues; the only hard stop is a first run with no prior env.

## Setup

### Phase 1 — bws project setup (one-time, off-host)

Create the secrets in Bitwarden Secrets Manager and record their UUIDs in the
maps, then commit:

- App secrets → `compose/env/*.secrets.map`
- restic/S3 (endpoint+bucket as `RESTIC_S3_ROOT`, access keys, repo password) →
  `backup/restic.secrets.map`

This is data entry in bws plus pasting UUIDs. It is not a host step and can't be
scripted (the script can't invent secret UUIDs).

### Phase 2 — host bootstrap (single command)

Prereqs on the Pi: Docker with the Compose v2 plugin (**≥ 2.20**) and `mise`.

```bash
sudo git clone <repo-url> /opt/homelab-pi
cd /opt/homelab-pi
sudo ./bin/bootstrap
```

`bin/bootstrap` prompts for `BWS_ACCESS_TOKEN` only if it isn't already present,
then does everything else with no further input: installs the toolchain via
`mise`, creates the rollback dir, installs and enables the timers, and runs the
first apply + first backup so the system is live on exit. It is idempotent —
safe to re-run.

## Everyday operations

- **On-demand update:** `sudo systemctl start homelab-apply` (or run
  `./bin/apply` directly). Idempotent; reconverges the stack every run.
- **One service:** `docker compose stop|start|logs zigbee2mqtt`.
- **Add an app:** drop `compose/<app>.yaml`, add one line to `compose.yaml`'s
  `include:`, add `compose/env/<app>.secrets.map` (may be empty), and — if the
  app is stateful — a profile in `backup/profiles.yaml` plus an entry in
  `bin/lib.sh`'s `hl_app_datadir`. Add any hardware needs to
  `compose/hardware.yaml`. No changes to the drivers or systemd units.
- **Restore:** `sudo ./bin/restore <app> [snapshot-id]`. Stops the service,
  writes a timestamped rollback tarball to `/opt/backups/homelab-pi/` (so you can
  undo the restore itself), restores from restic (`latest` unless you pass a
  snapshot id), then restarts the service only if the restore succeeded. Refuses
  stateless apps. To undo a restore, extract the rollback tarball back into the
  data dir's parent while the service is stopped.

## Updates and linting

Renovate manages `image:` tags across `compose/**` and tool versions in
`mise.toml`; both arrive as PRs to be merged. Validation is entirely linting (no
build). Run it locally with pre-commit:

```bash
pre-commit install          # one-time; enables commitlint on commit-msg
pre-commit run --all-files
```

CI (`.github/workflows/lint.yaml`) runs the same pre-commit suite plus GitHub
Actions, Renovate-config, and commit-message checks. The bats test suite runs in
`.github/workflows/test.yaml`.

## Firewall note (IoT VLAN)

The Pi is pull-based by design: it reaches **out** to the git remote, the
Bitwarden API, and the S3 endpoint, and accepts nothing inbound. Ensure egress to
those three destinations is permitted; nothing needs to reach in.
