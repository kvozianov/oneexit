# shellcheck shell=bash
# oneexit client: pf ruleset rendering (pure functions) and anchor helpers.
# Requires common.sh to be sourced first (run, write_file, is_ipv4, ...).

# _pf_iface_set IFACE...: "{ en0 en1 }" (default "{ en0 }").
_pf_iface_set() {
  local IFS=' '
  if [ "$#" -eq 0 ]; then
    set -- en0
  fi
  printf '{ %s }' "$*"
}

# _pf_check_args VPS_IP VPS_PORT TUN_IFACE IFACE...: validate before rendering.
_pf_check_args() {
  local ip="$1" port="$2" tun="$3" iface
  shift 3
  if ! is_ipv4 "${ip}"; then
    printf 'render_pf: VPS_IP must be an IPv4 address, got "%s"\n' "${ip}" >&2
    return 2
  fi
  if ! is_port "${port}"; then
    printf 'render_pf: VPS_PORT must be 1-65535, got "%s"\n' "${port}" >&2
    return 2
  fi
  if ! is_utun_name "${tun}"; then
    printf 'render_pf: TUN_IFACE must be a utun device such as utun3, got "%s"\n' "${tun}" >&2
    return 2
  fi
  for iface in "$@"; do
    if ! is_iface_name "${iface}"; then
      printf 'render_pf: invalid interface name "%s"\n' "${iface}" >&2
      return 2
    fi
  done
  return 0
}

# _render_pf_rules MODE VPS_IP VPS_PORT TUN_IFACE [IFACE...]  (MODE: locked | portal)
_render_pf_rules() {
  local mode="$1" ip port tun ifs
  shift
  if [ "$#" -lt 3 ]; then
    printf 'usage: render_pf VPS_IP VPS_PORT TUN_IFACE [IFACE...]\n' >&2
    return 2
  fi
  _pf_check_args "$@" || return 2
  ip="$1"
  port="$2"
  tun="$3"
  shift 3
  ifs="$(_pf_iface_set "$@")"
  printf '%s\n' \
    "# oneexit kill switch (generated; do not edit)" \
    "set block-policy drop" \
    "pass quick on lo0 all no state" \
    "block all" \
    "block quick inet6 all" \
    "pass out quick on ${ifs} proto udp from any to ${ip} port ${port} keep state" \
    "pass out quick on ${ifs} proto udp from port 68 to port 67 keep state" \
    "pass in quick on ${ifs} proto udp from port 67 to port 68 keep state"
  if [ "${mode}" = "portal" ]; then
    printf '%s\n' \
      "pass out quick on ${ifs} proto tcp from any to any port { 80 443 } keep state" \
      "pass out quick on ${ifs} proto udp from any to any port 53 keep state"
  fi
  printf '%s\n' \
    "pass out quick on ${tun} proto { tcp udp icmp } all keep state" \
    "pass in quick on ${tun} proto icmp all keep state"
}

# render_pf VPS_IP VPS_PORT TUN_IFACE [IFACE...]: the locked kill-switch ruleset.
# TUN_IFACE is the live utun device (utun99 placeholder while the tunnel is down).
render_pf() { _render_pf_rules locked "$@"; }

# render_pf_portal VPS_IP VPS_PORT TUN_IFACE [IFACE...]: locked + HTTP(S) and
# DNS out on the physical interfaces, for logging in to a captive portal.
render_pf_portal() { _render_pf_rules portal "$@"; }

# render_pf_unlocked: everything allowed (oneexit unlock).
render_pf_unlocked() { printf 'pass all\n'; }

# render_pf_failsafe: used when the config is missing or broken; blocks
# everything except loopback and DHCP so the machine fails closed.
render_pf_failsafe() {
  printf '%s\n' \
    "# oneexit kill switch: config missing, failing closed (generated; do not edit)" \
    "set block-policy drop" \
    "pass quick on lo0 all no state" \
    "block all" \
    "block quick inet6 all" \
    "pass out quick proto udp from port 68 to port 67 keep state" \
    "pass in quick proto udp from port 67 to port 68 keep state"
}

# ---------------------------------------------------------------- pfctl wrappers

# pf_enabled: 0 if pf reports "Status: Enabled" (needs root to read).
pf_enabled() {
  command -v pfctl >/dev/null 2>&1 || return 1
  pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'
}

# pf_anchor_loaded: 0 if the oneexit anchor has at least one rule.
pf_anchor_loaded() {
  local rules
  command -v pfctl >/dev/null 2>&1 || return 1
  rules="$(pfctl -a "${ONEEXIT_ANCHOR}" -s rules 2>/dev/null)" || return 1
  [ -n "${rules}" ]
}

# pf_main_has_hook: 0 if the main ruleset has the stock anchor "com.apple/*"
# (without it our anchor is never evaluated), 1 if it is missing, 2 if the
# main ruleset cannot be read (not root, no pfctl).
pf_main_has_hook() {
  local rules
  command -v pfctl >/dev/null 2>&1 || return 2
  rules="$(pfctl -s rules 2>/dev/null)" || return 2
  if printf '%s\n' "${rules}" | grep -Eq '^anchor "com\.apple/\*"'; then
    return 0
  fi
  return 1
}

# pf_conf_has_hook [FILE]: 0 if FILE (default /etc/pf.conf) declares the
# anchor "com.apple/*" hook, 1 if not, 2 if FILE is unreadable.
pf_conf_has_hook() {
  local file="${1:-${ONEEXIT_PF_CONF}}"
  [ -r "${file}" ] || return 2
  if grep -Eq '^[[:space:]]*anchor[[:space:]]+"com\.apple/\*"' "${file}"; then
    return 0
  fi
  return 1
}

# shellcheck disable=SC2034 # used by the scripts that source this file
PF_HOOK_MISSING_MSG='main pf ruleset has no "com.apple/*" anchor; the kill switch is not active'

# pf_enable: enable pf (takes a reference; harmless if already enabled).
pf_enable() { run pfctl -E; }

# pf_load_ruleset FILE: load FILE into the oneexit anchor.
pf_load_ruleset() { run pfctl -a "${ONEEXIT_ANCHOR}" -f "$1"; }

# pf_flush_anchor: remove every rule from the oneexit anchor.
pf_flush_anchor() { run pfctl -a "${ONEEXIT_ANCHOR}" -F all; }

# ---------------------------------------------------------------- lock modes

# pf_mode_until NAME: epoch from ${ONEEXIT_RUN_DIR}/NAME-until, if valid.
pf_mode_until() {
  local file="${ONEEXIT_RUN_DIR}/$1-until" value
  [ -r "${file}" ] || return 1
  value="$(head -n 1 "${file}" 2>/dev/null | tr -d '[:space:]')"
  is_uint "${value}" || return 1
  printf '%s\n' "${value}"
}

# pf_current_mode [NOW]: prints "unlocked UNTIL", "portal UNTIL" or "locked".
# Expired timers count as locked.
pf_current_mode() {
  local now="${1:-}" until
  [ -n "${now}" ] || now="$(now_epoch)"
  if until="$(pf_mode_until unlock)" && [ "${until}" -gt "${now}" ]; then
    printf 'unlocked %s\n' "${until}"
  elif until="$(pf_mode_until portal)" && [ "${until}" -gt "${now}" ]; then
    printf 'portal %s\n' "${until}"
  else
    printf 'locked\n'
  fi
}

# pf_rules_file MODE: where the ruleset for MODE is written before loading.
pf_rules_file() {
  case "$1" in
    locked) printf '%s\n' "${ONEEXIT_ANCHOR_FILE}" ;;
    portal) printf '%s\n' "${ONEEXIT_RUN_DIR}/portal.rules" ;;
    unlocked) printf '%s\n' "${ONEEXIT_RUN_DIR}/unlocked.rules" ;;
    failsafe) printf '%s\n' "${ONEEXIT_RUN_DIR}/failsafe.rules" ;;
    *) return 2 ;;
  esac
}

# pf_render_mode MODE: render the ruleset for MODE from the loaded config
# (VPS_IP, VPS_PORT, PHYS_IFACES) and the live tunnel interface (TUN_IFACE if
# set, else tunnel_iface_or_placeholder). Falls back to the failsafe ruleset.
pf_render_mode() {
  local mode="$1" tun="${TUN_IFACE:-}"
  [ -n "${tun}" ] || tun="$(tunnel_iface_or_placeholder)"
  # shellcheck disable=SC2086 # PHYS_IFACES is a space-separated list
  set -- ${PHYS_IFACES:-}
  case "${mode}" in
    unlocked) render_pf_unlocked ;;
    failsafe) render_pf_failsafe ;;
    portal | locked)
      if [ -z "${VPS_IP:-}" ] || [ -z "${VPS_PORT:-}" ]; then
        render_pf_failsafe
      elif [ "${mode}" = "portal" ]; then
        render_pf_portal "${VPS_IP}" "${VPS_PORT}" "${tun}" "$@"
      else
        render_pf "${VPS_IP}" "${VPS_PORT}" "${tun}" "$@"
      fi
      ;;
    *) return 2 ;;
  esac
}

# pf_current_rules: the ruleset text last loaded into the anchor.
pf_current_rules() {
  local file="${ONEEXIT_RUN_DIR}/current.pf"
  [ -r "${file}" ] || return 1
  cat "${file}"
}

# pf_apply_mode MODE [RULES]: write the ruleset for MODE to its file, load it
# into the anchor and remember it in ${ONEEXIT_RUN_DIR}/current.pf.
pf_apply_mode() {
  local mode="$1" rules="${2:-}" file
  file="$(pf_rules_file "${mode}")" || return 2
  if [ -z "${rules}" ]; then
    rules="$(pf_render_mode "${mode}")" || return 1
  fi
  printf '%s\n' "${rules}" | write_file "${file}" 0644
  pf_load_ruleset "${file}" || return 1
  printf '%s\n' "${rules}" | write_file "${ONEEXIT_RUN_DIR}/current.pf" 0644
}
