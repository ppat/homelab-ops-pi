#!/usr/bin/env bats
# Exercises bin/backup against a real resticprofile + a local filesystem
# restic repo (no S3/network needed — restic's local backend is hermetic)
# and real quiesce hooks (start/stop) against real base-stack containers.

setup() {
  load helpers/setup
  hl_test_setup_common
  hl_test_setup_repo_checkout

  # App data dirs live under the per-test HL_DATA_ROOT tmp dir — the same path
  # hl_app_datadir() and backup/profiles.yaml's ${HL_DATA_ROOT} resolve to. No
  # real /opt, no sudo. Seed data there for restic to actually snapshot.
  hl_test_make_datadirs
  echo "z2m fixture data" >"${HL_DATA_ROOT}/zigbee2mqtt/data/database.db"
  echo "zwave fixture data" >"${HL_DATA_ROOT}/zwave-js/data/store.json"

  hl_test_write_restic_map

  # Bring the base-stack containers up for real so the quiesce hooks (compose
  # stop/start <app>) in backup/profiles.yaml have something to act on. This
  # bypasses bin/apply, so the env_file: targets it would normally render need
  # to exist some other way first.
  hl_test_stub_app_envs
  docker compose --project-directory "${HL_REPO_ROOT}" up -d zigbee2mqtt zwave-js-ui
}

teardown() {
  hl_test_teardown
}

@test "backup: full-backup cycle creates a snapshot per app in the local restic repo, quiescing and restarting the service" {
  run "${HL_REPO_ROOT}/bin/backup"
  [ "$status" -eq 0 ]

  # Quiesce hooks must have left the services running afterward.
  run hl_test_running_services
  echo "$output" | grep -q zigbee2mqtt
  echo "$output" | grep -q zwave-js-ui

  # shellcheck disable=SC1091
  source "${HL_ENV_DIR}/restic.env"
  export RESTIC_PASSWORD RESTIC_REPOSITORY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

  RESTIC_REPOSITORY="${RESTIC_S3_ROOT}/zigbee2mqtt"
  run restic snapshots --json
  [ "$status" -eq 0 ]
  [ "$output" != "[]" ]
  [ "$output" != "null" ]

  RESTIC_REPOSITORY="${RESTIC_S3_ROOT}/zwave-js-ui"
  run restic snapshots --json
  [ "$status" -eq 0 ]
  [ "$output" != "[]" ]
  [ "$output" != "null" ]
}

@test "backup: fail-closed restic creds — a bws outage aborts before touching any container" {
  : >"${HL_TEST_BWS_SECRETS}"
  hl_test_bws_set aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa __FAIL__

  run "${HL_REPO_ROOT}/bin/backup"
  [ "$status" -ne 0 ]

  # Services untouched — the creds failure happened before any quiesce hook ran.
  run hl_test_running_services
  echo "$output" | grep -q zigbee2mqtt
  echo "$output" | grep -q zwave-js-ui
}
