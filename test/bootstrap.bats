#!/usr/bin/env bats
# Exercises bin/bootstrap for real: real `mise install`, real docker compose
# (base stack). Only `systemctl` is stubbed (test/helpers/stubs/systemctl) —
# bootstrap must not enable/reload real units on the shared GitHub-hosted runner.
#
# Runs UNPRIVILEGED (no sudo): every host path bootstrap writes is a per-test tmp
# dir via the HL_* overrides — HL_REPO_ROOT (a real, if remote-less, git repo),
# HL_ENV_DIR, HL_DATA_ROOT, HL_SYSTEMD_DIR — and systemctl is stubbed, so nothing
# needs privilege and nothing touches the real /opt or /etc. bootstrap only pins
# HOME=/root when it actually is root; here it inherits the test user's HOME, so
# `mise install` resolves against the same mise the rest of the suite uses. The
# base stack (COMPOSE_FILE=compose.yaml, no hardware overlay) converges without
# dongles. Safe because CI runners are single-use throwaway VMs.

setup() {
  load helpers/setup
  hl_test_setup_common

  export HL_REPO_ROOT; HL_REPO_ROOT="$(hl_test_tmpdir repo)"
  export HL_SYSTEMD_DIR; HL_SYSTEMD_DIR="$(hl_test_tmpdir systemd)"
  # Base stack only — no dongles on the runner.
  export COMPOSE_FILE=compose.yaml

  git -C "${HL_SRC_REPO_ROOT}" archive HEAD | tar -x -C "${HL_REPO_ROOT}"
  # bin/apply (bootstrap's first-run converge) runs `git rev-parse HEAD`; a bare
  # archive extraction has no .git, a hard `set -e` failure (not the soft "git
  # pull failed" warning apply tolerates). Make it a real (remote-less) repo so
  # converge gets past that before touching bws/compose.
  git -C "${HL_REPO_ROOT}" init --quiet
  git -C "${HL_REPO_ROOT}" config user.email test@example.com
  git -C "${HL_REPO_ROOT}" config user.name test
  git -C "${HL_REPO_ROOT}" add -A
  git -C "${HL_REPO_ROOT}" commit --quiet -m seed

  # App data dirs (base stack volumes bind here under HL_DATA_ROOT).
  hl_test_make_datadirs

  # bootstrap's first converge needs zwave-js-ui's one secret + all four restic
  # secrets to resolve so bin/apply / bin/backup succeed.
  hl_test_bws_set 00000000-0000-0000-0000-000000000000 test-secret-value
  hl_test_write_restic_map
}

teardown() {
  # Tear down any containers the first converge brought up. Everything else lives
  # under BATS_TEST_TMPDIR (owned by the test user now that bootstrap runs
  # unprivileged) and bats removes it — no sudo cleanup needed.
  docker compose --project-directory "${HL_REPO_ROOT}" down -v --remove-orphans \
    >/dev/null 2>&1 || true
}

# hl_run_bootstrap
#   Runs bootstrap unprivileged. bootstrap no longer requires root: every host
#   path it writes (HL_ENV_DIR / HL_SYSTEMD_DIR / HL_ROLLBACK_DIR / HL_DATA_ROOT)
#   is a writable tmp dir here and systemctl is stubbed, so there is nothing left
#   that needs privilege — dropping sudo keeps the whole run as the test user and
#   avoids sudo's environment reset entirely.
#
#   MISE_DISABLE_TOOLS=bitwarden-secrets-manager: bootstrap's first converge runs
#   `mise exec -- apply`, which re-prepends mise's install dirs to PATH ahead of
#   our stub dir, shadowing the bws stub with the real (network-bound) bws.
#   Disabling just that one mise tool drops it from the exec PATH so the stub on
#   PATH wins — every other mise tool (restic/resticprofile/zstd/jq) stays real.
hl_run_bootstrap() {
  MISE_DISABLE_TOOLS=bitwarden-secrets-manager "${HL_REPO_ROOT}/bin/bootstrap"
}

@test "bootstrap: enforces the Compose >=2.20 version floor" {
  local old_compose_dir; old_compose_dir="$(hl_test_tmpdir old-compose-stub)"
  cat >"${old_compose_dir}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "compose version" && "${3:-}" == "--short" ]]; then
  echo "2.19.0"
  exit 0
fi
[[ "$1 $2" == "compose version" ]] && exit 0
exec /usr/bin/docker "$@"
EOF
  chmod +x "${old_compose_dir}/docker"
  export PATH="${old_compose_dir}:${PATH}"

  run hl_run_bootstrap
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "2.20"
}

@test "bootstrap: converges the stack and enables the timers via a mise-native first run" {
  run hl_run_bootstrap
  [ "$status" -eq 0 ]

  run systemctl is-enabled homelab-apply.timer
  [ "$status" -eq 0 ]
  [ "$output" = "enabled" ]

  run systemctl is-enabled homelab-backup.timer
  [ "$status" -eq 0 ]
  [ "$output" = "enabled" ]

  # The first apply/backup only succeed if bws/restic/resticprofile resolved via
  # `mise exec` post-install — a real running container is proof apply's compose
  # step ran end to end.
  run hl_test_running_services
  echo "$output" | grep -q zigbee2mqtt
}

@test "bootstrap: is idempotent — a second run does not re-prompt and still succeeds" {
  hl_run_bootstrap
  run hl_run_bootstrap
  [ "$status" -eq 0 ]
}
