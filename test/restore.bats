#!/usr/bin/env bats
# Exercises bin/restore against a real resticprofile/local restic repo:
# restart-only-on-success, and --delete producing a clean replace (not a merge).

# Required for `run !` (negated run) to actually assert failure rather than warn.
bats_require_minimum_version 1.5.0

setup() {
  load helpers/setup
  hl_test_setup_common
  hl_test_setup_repo_checkout

  # App data dirs under the per-test HL_DATA_ROOT tmp dir (see backup.bats).
  hl_test_make_datadirs
  echo "original content" >"${HL_DATA_ROOT}/zigbee2mqtt/data/database.db"

  hl_test_write_restic_map

  # Bypasses bin/apply, so the env_file: targets it would normally render
  # need to exist some other way first.
  hl_test_stub_app_envs
  docker compose --project-directory "${HL_REPO_ROOT}" up -d zigbee2mqtt zwave-js-ui

  # Snapshot the "original content" state via a real backup, so restore has
  # a real snapshot to restore from.
  "${HL_REPO_ROOT}/bin/backup"
}

teardown() {
  hl_test_teardown
}

@test "restore: successful restore restarts the service and reproduces snapshot content exactly (--delete)" {
  local datadir="${HL_DATA_ROOT}/zigbee2mqtt/data"
  # Mutate + plant a stray file after the snapshot was taken.
  echo "corrupted" >"${datadir}/database.db"
  echo "should not survive a --delete restore" >"${datadir}/stray-file.txt"

  run "${HL_REPO_ROOT}/bin/restore" zigbee2mqtt
  [ "$status" -eq 0 ]

  [ "$(cat "${datadir}/database.db")" = "original content" ]
  [ ! -f "${datadir}/stray-file.txt" ]

  run hl_test_running_services
  echo "$output" | grep -q zigbee2mqtt
}

@test "restore: a failing restore (invalid snapshot id) does NOT restart the service and surfaces the rollback path" {
  run "${HL_REPO_ROOT}/bin/restore" zigbee2mqtt not-a-real-snapshot-id
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "rollback artifact"

  run hl_test_running_services
  run ! grep -q zigbee2mqtt <<<"$output"
}

@test "restore: refuses a stateless app" {
  run "${HL_REPO_ROOT}/bin/restore" theengsgateway
  [ "$status" -ne 0 ]
}

@test "restore: refuses an unknown app" {
  run "${HL_REPO_ROOT}/bin/restore" not-a-real-app
  [ "$status" -ne 0 ]
}
