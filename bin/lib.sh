#!/usr/bin/env bash
# Shared helpers for bin/apply and bin/backup. Sourced, not executed.
#
# Conventions:
#   - All functions prefixed hl_ to avoid collisions.
#   - Logging goes to stderr so stdout stays clean for any future capture.
#   - Callers set `set -Eeuo pipefail`; this lib assumes it.

# --- paths (override via environment for testing) --------------------------
: "${HL_REPO_ROOT:=/opt/homelab-pi}"          # where the git repo lives on host
: "${HL_ENV_DIR:=/etc/homelab-pi}"            # where generated *.env are written
: "${HL_COMPOSE_ENV_DIR:=${HL_REPO_ROOT}/compose/env}"

# --- logging ---------------------------------------------------------------
hl_log()  { printf '%s [%s] %s\n' "$(date -Is)" "${1}" "${2}" >&2; }
hl_info() { hl_log INFO  "$*"; }
hl_warn() { hl_log WARN  "$*"; }
hl_err()  { hl_log ERROR "$*"; }

# --- bws availability ------------------------------------------------------
# Requires BWS_ACCESS_TOKEN in the environment (provided by systemd
# EnvironmentFile=/etc/homelab-pi/bws.env, or the user's shell for manual runs).
hl_require_bws() {
  if ! command -v bws >/dev/null 2>&1; then
    hl_err "bws CLI not found on PATH (is mise activated?)"; return 1
  fi
  if [[ -z "${BWS_ACCESS_TOKEN:-}" ]]; then
    hl_err "BWS_ACCESS_TOKEN is not set; cannot resolve secrets"; return 1
  fi
}

# hl_bws_get <uuid> -> prints secret value on stdout, non-zero on any failure.
hl_bws_get() {
  local uuid="$1" val
  # `bws secret get <id>` emits JSON; extract .value. Fail if empty/missing.
  if ! val="$(bws secret get "${uuid}" 2>/dev/null | jq -er '.value')"; then
    return 1
  fi
  [[ -n "${val}" ]] || return 1
  printf '%s' "${val}"
}

# hl_render_env <app>
#   Reads compose/env/<app>.secrets.map, resolves each UUID via bws, and writes
#   ${HL_ENV_DIR}/<app>.env ATOMICALLY.
#
#   Fail-closed semantics (per design): if ANY secret in the map fails to
#   resolve, the existing <app>.env is left UNTOUCHED (last-good preserved) and
#   the function returns 2 (soft failure). The whole apply continues.
#   The only hard-failure case is first run with no prior env to fall back on,
#   which returns 3.
#
#   Return codes:
#     0 = env written (content may or may not have changed; caller hashes)
#     2 = resolve failed, last-good preserved
#     3 = resolve failed AND no prior env exists (hard: cannot start clean)
#
# hl_render_map <label> <map-path> <dest-path>
#   Core renderer: reads a secrets map, resolves each UUID via bws, writes dest
#   atomically. Same fail-closed contract as above. <label> is only for logs.
hl_render_map() {
  local label="$1" map="$2" dest="$3"
  local tmp; tmp="$(mktemp)"

  if [[ ! -f "${map}" ]]; then
    hl_err "missing secrets map: ${map}"; rm -f "${tmp}"; return 3
  fi

  local line var uuid val failed=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    var="${line%%=*}"
    uuid="${line#*=}"
    var="$(printf '%s' "${var}" | tr -d '[:space:]')"
    uuid="$(printf '%s' "${uuid}" | tr -d '[:space:]')"
    if ! val="$(hl_bws_get "${uuid}")"; then
      hl_warn "bws resolve failed for ${label}:${var} (${uuid})"
      failed=1
      break
    fi
    printf '%s=%s\n' "${var}" "${val}" >>"${tmp}"
  done <"${map}"

  if [[ "${failed}" -ne 0 ]]; then
    rm -f "${tmp}"
    if [[ -f "${dest}" ]]; then
      hl_warn "${label}: preserving last-good ${dest}"
      return 2
    fi
    hl_err "${label}: no prior env to fall back on; cannot render"
    return 3
  fi

  install -m 0640 "${tmp}" "${dest}"
  rm -f "${tmp}"
  hl_info "${label}: wrote ${dest}"
  return 0
}

# hl_render_env <app> -> renders compose/env/<app>.secrets.map to <app>.env
hl_render_env() {
  local app="$1"
  hl_render_map "${app}" \
    "${HL_COMPOSE_ENV_DIR}/${app}.secrets.map" \
    "${HL_ENV_DIR}/${app}.env"
}

# retained for reference; superseded by hl_render_map above.

# hl_hash <file> -> stable content hash, or the literal "absent"
hl_hash() {
  [[ -f "$1" ]] && sha256sum "$1" | cut -d' ' -f1 || printf 'absent'
}

# --- compose + app metadata ------------------------------------------------
# Single source of truth for the compose invocation, so every script targets
# the same project regardless of cwd.
hl_compose() {
  docker --project-directory "${HL_REPO_ROOT}" compose "$@"
}

# Path where pre-restore rollback tarballs are written.
: "${HL_ROLLBACK_DIR:=/opt/backups/homelab-pi}"

# Map an app -> its on-disk data directory. Stateless apps map to empty string.
# Kept here (not scattered across scripts) so adding an app updates one place.
hl_app_datadir() {
  case "$1" in
    zigbee2mqtt) printf '/opt/zigbee2mqtt/data' ;;
    zwave-js-ui) printf '/opt/zwave-js/data' ;;
    theengsgateway) printf '' ;;   # stateless
    *) return 1 ;;                  # unknown app
  esac
}
