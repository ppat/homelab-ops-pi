#!/usr/bin/env bats
# Exercises bin/apply against a real git fixture + real docker compose (base
# stack, hardware-free) + a stubbed bws. Runs in CI only (needs Docker); see
# test/helpers/setup.bash.

# Required for `run !` (negated run) to actually assert failure rather than warn.
bats_require_minimum_version 1.5.0

setup() {
  load helpers/setup
  hl_test_setup_common
  hl_test_setup_git_fixture

  # zigbee2mqtt/zwave-js-ui secrets maps have no real entries needed for a
  # clean render (z2m's map is comment-only; zwave's one entry we stub here).
  hl_test_bws_set 00000000-0000-0000-0000-000000000000 test-secret-value
}

teardown() {
  hl_test_teardown
}

@test "apply: converges the stack (containers running) on a clean checkout" {
  run "${HL_REPO_ROOT}/bin/apply"
  [ "$status" -eq 0 ]

  run hl_test_running_services
  [ "$status" -eq 0 ]
  echo "$output" | grep -q zigbee2mqtt
  echo "$output" | grep -q zwave-js-ui
}

@test "apply: is unconditionally self-healing — re-converges a manually-stopped container even with nothing else changed" {
  "${HL_REPO_ROOT}/bin/apply"

  docker compose --project-directory "${HL_REPO_ROOT}" stop zigbee2mqtt
  run hl_test_running_services
  run ! grep -q zigbee2mqtt <<<"$output"

  # Nothing changed on any input axis (git HEAD, env hash) — only a manual stop
  # happened. apply must still bring it back (self-healing).
  run "${HL_REPO_ROOT}/bin/apply"
  [ "$status" -eq 0 ]

  run hl_test_running_services
  echo "$output" | grep -q zigbee2mqtt
}

@test "apply: git pull --ff-only actually advances HEAD when the fixture origin moves forward" {
  "${HL_REPO_ROOT}/bin/apply"
  local before; before="$(git -C "${HL_REPO_ROOT}" rev-parse HEAD)"

  local advanced; advanced="$(hl_test_git_fixture_advance)"
  [ "${before}" != "${advanced}" ]

  run "${HL_REPO_ROOT}/bin/apply"
  [ "$status" -eq 0 ]

  local after; after="$(git -C "${HL_REPO_ROOT}" rev-parse HEAD)"
  [ "${after}" = "${advanced}" ]
}

@test "apply: fail-closed env rendering — a bws outage for one app's secret preserves that app's last-good env while others still render" {
  # First run: zwave-js-ui's secret resolves, env gets written.
  "${HL_REPO_ROOT}/bin/apply"
  local zwave_env="${HL_ENV_DIR}/zwave-js-ui.env"
  [ -f "${zwave_env}" ]
  local before; before="$(sha256sum "${zwave_env}" | cut -d' ' -f1)"

  # Simulate a bws outage for that one secret on the next run.
  : >"${HL_TEST_BWS_SECRETS}"
  hl_test_bws_set 00000000-0000-0000-0000-000000000000 __FAIL__

  run "${HL_REPO_ROOT}/bin/apply"
  [ "$status" -eq 0 ]

  # Last-good preserved, byte-for-byte, despite the resolve failure.
  local after; after="$(sha256sum "${zwave_env}" | cut -d' ' -f1)"
  [ "${before}" = "${after}" ]

  # zigbee2mqtt's map has no secrets at all (comment-only, never touches bws)
  # so it renders successfully every run regardless — confirms the failure
  # above didn't abort the whole apply for the other apps.
  [ -f "${HL_ENV_DIR}/zigbee2mqtt.env" ]
}
