#!/usr/bin/env bats
# Unit tests for bin/lib.sh — shared helpers used by every driver script.

setup() {
  load helpers/setup
  hl_test_setup_common
  export HL_REPO_ROOT; HL_REPO_ROOT="$(hl_test_tmpdir repo)"
  # shellcheck disable=SC1091
  source "${HL_SRC_REPO_ROOT}/bin/lib.sh"
}

# --- hl_hash -----------------------------------------------------------------

@test "hl_hash: returns 'absent' for a missing file" {
  run hl_hash "${BATS_TEST_TMPDIR}/does-not-exist"
  [ "$status" -eq 0 ]
  [ "$output" = "absent" ]
}

@test "hl_hash: returns a stable sha256 for an existing file, changes on content change" {
  local f="${BATS_TEST_TMPDIR}/f"
  echo "one" >"${f}"
  run hl_hash "${f}"
  local h1="$output"
  [ -n "$h1" ]
  echo "two" >"${f}"
  run hl_hash "${f}"
  local h2="$output"
  [ "$h1" != "$h2" ]
}

# --- hl_app_datadir ------------------------------------------------------------

@test "hl_app_datadir: known stateful apps map to their data dir under HL_DATA_ROOT" {
  run hl_app_datadir zigbee2mqtt
  [ "$status" -eq 0 ]
  [ "$output" = "${HL_DATA_ROOT}/zigbee2mqtt/data" ]

  run hl_app_datadir zwave-js-ui
  [ "$status" -eq 0 ]
  [ "$output" = "${HL_DATA_ROOT}/zwave-js/data" ]
}

@test "hl_app_datadir: honors HL_DATA_ROOT override (parameterized, not hardcoded /opt)" {
  HL_DATA_ROOT=/custom/root run hl_app_datadir zigbee2mqtt
  [ "$status" -eq 0 ]
  [ "$output" = "/custom/root/zigbee2mqtt/data" ]
}

@test "hl_app_datadir: stateless app maps to empty string, exit 0" {
  run hl_app_datadir theengsgateway
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "hl_app_datadir: unknown app returns non-zero" {
  run hl_app_datadir not-a-real-app
  [ "$status" -ne 0 ]
}

# --- hl_render_map: fail-closed contract --------------------------------------

@test "hl_render_map: all secrets resolve -> writes dest, returns 0" {
  local map="${BATS_TEST_TMPDIR}/ok.map" dest="${HL_ENV_DIR}/ok.env"
  hl_test_bws_set 11111111-1111-1111-1111-111111111111 hello
  cat >"${map}" <<'EOF'
FOO=11111111-1111-1111-1111-111111111111
EOF
  run hl_render_map testlabel "${map}" "${dest}"
  [ "$status" -eq 0 ]
  [ -f "${dest}" ]
  grep -q '^FOO=hello$' "${dest}"
}

@test "hl_render_map: empty map (comments only) -> writes empty dest, returns 0" {
  local map="${BATS_TEST_TMPDIR}/empty.map" dest="${HL_ENV_DIR}/empty.env"
  echo "# nothing here" >"${map}"
  run hl_render_map testlabel "${map}" "${dest}"
  [ "$status" -eq 0 ]
  [ -f "${dest}" ]
  [ ! -s "${dest}" ]
}

@test "hl_render_map: missing map file -> hard failure (3), no dest written" {
  run hl_render_map testlabel "${BATS_TEST_TMPDIR}/nope.map" "${HL_ENV_DIR}/never.env"
  [ "$status" -eq 3 ]
  [ ! -f "${HL_ENV_DIR}/never.env" ]
}

@test "hl_render_map: secret resolve fails with NO prior dest -> hard failure (3)" {
  local map="${BATS_TEST_TMPDIR}/fail.map" dest="${HL_ENV_DIR}/fail.env"
  hl_test_bws_set 22222222-2222-2222-2222-222222222222 __FAIL__
  cat >"${map}" <<'EOF'
FOO=22222222-2222-2222-2222-222222222222
EOF
  run hl_render_map testlabel "${map}" "${dest}"
  [ "$status" -eq 3 ]
  [ ! -f "${dest}" ]
}

@test "hl_render_map: secret resolve fails WITH a prior dest -> soft failure (2), last-good preserved untouched" {
  local map="${BATS_TEST_TMPDIR}/soft.map" dest="${HL_ENV_DIR}/soft.env"
  printf 'FOO=last-good-value\n' >"${dest}"
  local before; before="$(hl_hash "${dest}")"

  hl_test_bws_set 33333333-3333-3333-3333-333333333333 __FAIL__
  cat >"${map}" <<'EOF'
FOO=33333333-3333-3333-3333-333333333333
EOF
  run hl_render_map testlabel "${map}" "${dest}"
  [ "$status" -eq 2 ]
  [ "$(hl_hash "${dest}")" = "${before}" ]
  grep -q '^FOO=last-good-value$' "${dest}"
}

@test "hl_render_map: is all-or-nothing — one failing secret among several resolvable ones writes nothing new" {
  local map="${BATS_TEST_TMPDIR}/partial.map" dest="${HL_ENV_DIR}/partial.env"
  hl_test_bws_set 44444444-4444-4444-4444-444444444444 good-value
  hl_test_bws_set 55555555-5555-5555-5555-555555555555 __FAIL__
  cat >"${map}" <<'EOF'
GOOD=44444444-4444-4444-4444-444444444444
BAD=55555555-5555-5555-5555-555555555555
EOF
  run hl_render_map testlabel "${map}" "${dest}"
  [ "$status" -eq 3 ]
  [ ! -f "${dest}" ]
}

@test "hl_render_env: renders compose/env/<app>.secrets.map into HL_ENV_DIR/<app>.env" {
  mkdir -p "${HL_REPO_ROOT}/compose/env"
  export HL_COMPOSE_ENV_DIR="${HL_REPO_ROOT}/compose/env"
  hl_test_bws_set 66666666-6666-6666-6666-666666666666 sekrit
  cat >"${HL_COMPOSE_ENV_DIR}/demo.secrets.map" <<'EOF'
TOKEN=66666666-6666-6666-6666-666666666666
EOF
  run hl_render_env demo
  [ "$status" -eq 0 ]
  grep -q '^TOKEN=sekrit$' "${HL_ENV_DIR}/demo.env"
}
