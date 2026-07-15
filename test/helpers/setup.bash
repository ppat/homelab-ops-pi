#!/usr/bin/env bash
# Shared Bats helper, loaded via `load helpers/setup` from every test/*.bats
# file. Provides per-test isolation via bin/lib.sh's environment-overridable
# paths (HL_REPO_ROOT / HL_ENV_DIR / HL_DATA_ROOT / HL_ROLLBACK_DIR).
#
# Real tools are used throughout (docker, compose, git, zstd, restic,
# resticprofile, mise). Only `bws` and `systemctl` are stubbed
# (test/helpers/stubs/{bws,systemctl}): bws because it would otherwise need
# live production credentials, systemctl because bootstrap.bats must not
# enable/disable/reload real units on the shared GitHub-hosted runner.
#
# The stack runs BASE compose.yaml only (no hardware overlay) — the base files
# are hardware-free and CI-runnable by construction, so nothing is stripped or
# redirected at test time. Host paths are pointed at per-test tmp dirs via the
# HL_* overrides; `docker compose --project-directory "${HL_REPO_ROOT}"` (the
# hl_compose choke point, and the profiles.yaml quiesce hooks) auto-discovers
# compose.yaml there, so COMPOSE_FILE is never set.

# Root of the actual checked-out repo (two levels up from this file).
HL_SRC_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &>/dev/null && pwd)"

# hl_test_tmpdir <suffix> -> fresh unique dir under BATS_TEST_TMPDIR, created.
hl_test_tmpdir() {
  local dir="${BATS_TEST_TMPDIR}/$1"
  mkdir -p "${dir}"
  printf '%s' "${dir}"
}

# hl_test_setup_common
#   Provisions the paths every test needs regardless of which script is under
#   test: HL_ENV_DIR, HL_DATA_ROOT, HL_ROLLBACK_DIR, a bws secrets map for the
#   stub, the systemctl stub state file, and PATH with the stub dir prepended.
#   Exports the path vars so `docker compose` interpolation
#   (${HL_ENV_DIR}/${HL_DATA_ROOT} in compose/*.yaml) resolves to these tmp
#   dirs when a test drives compose directly. Does NOT set HL_REPO_ROOT —
#   callers pick a repo-provisioning helper below first.
hl_test_setup_common() {
  export HL_ENV_DIR; HL_ENV_DIR="$(hl_test_tmpdir env)"
  export HL_DATA_ROOT; HL_DATA_ROOT="$(hl_test_tmpdir data)"
  export HL_ROLLBACK_DIR; HL_ROLLBACK_DIR="$(hl_test_tmpdir rollback)"

  export HL_TEST_BWS_SECRETS="${BATS_TEST_TMPDIR}/bws-secrets.map"
  : >"${HL_TEST_BWS_SECRETS}"

  # Tracks "enabled" units for the systemctl stub (bootstrap.bats) — bootstrap
  # must not touch the runner's real systemd/PID 1.
  export HL_TEST_SYSTEMCTL_STATE="${BATS_TEST_TMPDIR}/systemctl-enabled.list"
  : >"${HL_TEST_SYSTEMCTL_STATE}"

  export PATH="${HL_SRC_REPO_ROOT}/test/helpers/stubs:${PATH}"

  # hl_require_bws (bin/lib.sh) checks for this directly; every driver script
  # (apply/backup/restore) needs it set, not just bootstrap.bats.
  export BWS_ACCESS_TOKEN=test-token-value
}

# hl_test_make_datadirs
#   Creates the on-disk data dirs for the stateful apps under HL_DATA_ROOT,
#   matching hl_app_datadir()'s layout (and compose/profiles.yaml's
#   ${HL_DATA_ROOT}/<suffix>/data). Callers seed fixture content into them.
hl_test_make_datadirs() {
  mkdir -p "${HL_DATA_ROOT}/zigbee2mqtt/data" "${HL_DATA_ROOT}/zwave-js/data"
}

# hl_test_stub_app_envs
#   Touches empty env files for every app's env_file: entry, including
#   theengsgateway even though backup.bats/restore.bats only ever start/stop
#   zigbee2mqtt/zwave-js-ui -- compose resolves ALL services' env_file:
#   references from the `include:`d project up front, for any subcommand
#   (even one scoped to a single service), so a missing theengsgateway.env
#   fails backup/profiles.yaml's compose stop/start quiesce hooks too.
#   Normally bin/apply renders all of these from bws before compose ever
#   reads them; tests that bring containers up directly bypass bin/apply
#   entirely, so without this `docker compose` fails with "env file ... not
#   found". Content is irrelevant here — these tests exercise quiesce/restore,
#   not app config.
hl_test_stub_app_envs() {
  : >"${HL_ENV_DIR}/zigbee2mqtt.env"
  : >"${HL_ENV_DIR}/zwave-js-ui.env"
  : >"${HL_ENV_DIR}/theengsgateway.env"
}

# hl_test_running_services
#   `docker compose ps --services --filter status=running` silently ignores
#   the status filter when combined with --services on this compose version
#   (a long-standing, still-open upstream quirk: --services always lists every
#   service that has ever had a container in this project, live or stopped),
#   so it can't distinguish a stopped container from a running one. Parse
#   `--format json` instead (JSON Lines: one object per line, with reliable
#   .Service/.State fields) and filter on .State ourselves.
hl_test_running_services() {
  docker compose --project-directory "${HL_REPO_ROOT}" ps --format json \
    | jq -r 'select(.State == "running") | .Service'
}

# hl_test_bws_set <uuid> <value>
#   Registers a secret the bws stub will resolve. Pass value "__FAIL__" to
#   make that one secret resolve-fail (simulating a bws outage for it).
hl_test_bws_set() {
  printf '%s=%s\n' "$1" "$2" >>"${HL_TEST_BWS_SECRETS}"
}

# hl_test_write_restic_map
#   Points the checked-out repo's restic secrets map at stub uuids and
#   registers those uuids with the bws stub, aimed at a local filesystem restic
#   backend (no S3/network — restic's local backend is hermetic). Used by
#   backup/restore.bats.
hl_test_write_restic_map() {
  local restic_repo_root; restic_repo_root="$(hl_test_tmpdir restic-repo)"
  hl_test_bws_set aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa "local:${restic_repo_root}"
  hl_test_bws_set bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb test-restic-password
  hl_test_bws_set cccccccc-cccc-cccc-cccc-cccccccccccc unused-key-id
  hl_test_bws_set dddddddd-dddd-dddd-dddd-dddddddddddd unused-secret-key
  cat >"${HL_REPO_ROOT}/backup/restic.secrets.map" <<'EOF'
RESTIC_S3_ROOT=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
RESTIC_PASSWORD=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
AWS_ACCESS_KEY_ID=cccccccc-cccc-cccc-cccc-cccccccccccc
AWS_SECRET_ACCESS_KEY=dddddddd-dddd-dddd-dddd-dddddddddddd
EOF
}

# hl_test_setup_repo_checkout
#   Copies the real repo's tracked files into a fresh tmp HL_REPO_ROOT. For
#   tests that only need a valid project directory (backup/restore/lib), not
#   git-pull semantics.
hl_test_setup_repo_checkout() {
  export HL_REPO_ROOT; HL_REPO_ROOT="$(hl_test_tmpdir repo)"
  git -C "${HL_SRC_REPO_ROOT}" archive HEAD | tar -x -C "${HL_REPO_ROOT}"
}

# hl_test_setup_git_fixture
#   Creates a bare repo (seeded from this repo's tracked files) as a local
#   `origin`, then clones it into a fresh tmp HL_REPO_ROOT. No network calls.
#   For apply.bats, which needs `git pull --ff-only` to be real.
hl_test_setup_git_fixture() {
  local origin; origin="$(hl_test_tmpdir origin.git)"
  local seed; seed="$(hl_test_tmpdir seed)"
  git -C "${HL_SRC_REPO_ROOT}" archive HEAD | tar -x -C "${seed}"

  git init --quiet --bare "${origin}"
  (
    cd "${seed}" || exit 1
    git init --quiet
    git config user.email test@example.com
    git config user.name test
    git add -A
    git commit --quiet -m "seed"
    git branch -M main
    git remote add origin "${origin}"
    git push --quiet origin main
  )
  # A fresh `git init --bare` defaults HEAD to whatever init.defaultBranch is
  # configured (often "master"), which never gets created here since we only
  # ever push "main" -- leaving HEAD dangling and `git clone` unable to check
  # anything out ("remote HEAD refers to nonexistent ref"). Point it at the
  # branch we actually pushed.
  git -C "${origin}" symbolic-ref HEAD refs/heads/main

  export HL_TEST_GIT_ORIGIN="${origin}"
  export HL_TEST_GIT_SEED="${seed}"
  export HL_REPO_ROOT; HL_REPO_ROOT="$(hl_test_tmpdir repo)"
  # clone already checks out `main` (the default branch, since it's the only
  # one and HEAD points to it), tracking origin/main — exactly what `git pull
  # --ff-only` in bin/apply needs.
  git clone --quiet "${origin}" "${HL_REPO_ROOT}"
}

# hl_test_git_fixture_advance
#   Commits a trivial change to the seed checkout and pushes it to the local
#   origin, so a subsequent `git pull --ff-only` in HL_REPO_ROOT has
#   something new to fast-forward to. Returns the new HEAD sha on stdout.
hl_test_git_fixture_advance() {
  (
    cd "${HL_TEST_GIT_SEED}" || exit 1
    echo "advanced $(date +%s%N 2>/dev/null || echo x)" >>.ci-test-marker
    git add -A
    git commit --quiet -m "advance fixture"
    git push --quiet origin main
    git rev-parse HEAD
  )
}

# hl_test_teardown
#   Best-effort container cleanup (ignore failures: a test may have never
#   brought anything up). tmpdirs are cleaned by bats itself (all live under
#   BATS_TEST_TMPDIR), so nothing extra is needed there.
hl_test_teardown() {
  if [[ -n "${HL_REPO_ROOT:-}" && -f "${HL_REPO_ROOT}/compose.yaml" ]]; then
    docker compose --project-directory "${HL_REPO_ROOT}" down -v --remove-orphans \
      >/dev/null 2>&1 || true
  fi
}
