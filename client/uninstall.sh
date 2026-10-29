#!/usr/bin/env bash
# oneexit client uninstall: stop the daemons, remove the kill switch and
# restore the stock network configuration.
set -euo pipefail

_self="${BASH_SOURCE[0]}"
while [ -h "${_self}" ]; do
  _dir="$(cd -P "$(dirname "${_self}")" && pwd)"
  _self="$(readlink "${_self}")"
  case "${_self}" in /*) ;; *) _self="${_dir}/${_self}" ;; esac
done
SELF_DIR="$(cd -P "$(dirname "${_self}")" && pwd)"
LIB_DIR=""
for _cand in "${ONEEXIT_LIB_DIR:-}" "${SELF_DIR}/lib" /usr/local/libexec/oneexit/lib; do
  if [ -n "${_cand}" ] && [ -f "${_cand}/common.sh" ]; then
    LIB_DIR="${_cand}"
    break
  fi
done
if [ -z "${LIB_DIR}" ]; then
  echo "error: cannot find the oneexit libraries (common.sh)" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/pf.sh
. "${LIB_DIR}/pf.sh"

usage() {
  cat <<USAGE
Usage: sudo client/uninstall.sh [--keep-keys] [--dry-run] [--help]

Removes oneexit from this Mac:
  * stops and removes the launchd daemons ${ONEEXIT_FIREWALL_LABEL} and ${ONEEXIT_TUNNEL_LABEL}
  * brings the WireGuard tunnel down
  * flushes the pf anchor ${ONEEXIT_ANCHOR}; disables pf only if it was off before setup
  * sets IPv6 back to automatic and DNS back to DHCP on every network service
  * removes the installed files

Options:
  --keep-keys   keep ${ONEEXIT_WG_CONF} (the WireGuard private key)
  --dry-run     print every command instead of running it
  --help        show this help

Homebrew packages (wireguard-tools, wireguard-go) are left installed.
USAGE
}

KEEP_KEYS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-keys) KEEP_KEYS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      log_error "unknown option: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_root
load_config || true
if is_dry_run; then
  log_info "Dry run: nothing will be changed."
fi

log_step "Stopping launchd daemons"
for label in "${ONEEXIT_TUNNEL_LABEL}" "${ONEEXIT_FIREWALL_LABEL}"; do
  run launchctl bootout "system/${label}" 2>/dev/null || log_info "    ${label} was not loaded"
done

log_step "Bringing the tunnel down"
if command -v wg >/dev/null 2>&1 && wg show wg0 >/dev/null 2>&1; then
  run wg-quick down "${WG_IFACE_CONF}" || log_warn "wg-quick down failed"
elif is_dry_run; then
  run wg-quick down "${WG_IFACE_CONF}"
else
  log_info "    tunnel is not up"
fi

log_step "Removing launchd plists"
run rm -f "${ONEEXIT_LAUNCHD_DIR}/${ONEEXIT_FIREWALL_LABEL}.plist" \
  "${ONEEXIT_LAUNCHD_DIR}/${ONEEXIT_TUNNEL_LABEL}.plist"

log_step "Removing the pf anchor"
pf_flush_anchor || log_warn "could not flush anchor ${ONEEXIT_ANCHOR}"
pf_before="$(state_value PF_WAS_ENABLED || echo unknown)"
case "${pf_before}" in
  no)
    log_info "    pf was disabled before setup; disabling it again"
    run pfctl -d || log_warn "pfctl -d failed"
    ;;
  yes) log_info "    pf was enabled before setup; leaving it enabled" ;;
  *) log_info "    no record of the pf state before setup; leaving pf enabled (the anchor is empty)" ;;
esac
run rm -f "${ONEEXIT_ANCHOR_FILE}"

log_step "Restoring IPv6 and DNS on every network service"
services="$(network_services)"
while IFS= read -r service; do
  [ -n "${service}" ] || continue
  run networksetup -setv6automatic "${service}" || log_warn "could not restore IPv6 on \"${service}\""
done <<EOT
${services}
EOT
set_dns_all empty

log_step "Removing installed files"
run rm -f "${ONEEXIT_BIN}"
run rm -rf "${ONEEXIT_LIBEXEC}" "${ONEEXIT_RUN_DIR}" "${ONEEXIT_LOG_DIR}"
run rm -rf "${ONEEXIT_ETC_DIR}"
if [ "${KEEP_KEYS}" -eq 1 ]; then
  log_info "    keeping ${WG_IFACE_CONF} (--keep-keys)"
else
  run rm -f "${WG_IFACE_CONF}"
  run rmdir "${ONEEXIT_WG_DIR}" 2>/dev/null || true
fi

log_step "Done"
cat <<NEXT
oneexit is removed. Network services use DHCP DNS and automatic IPv6 again.
Homebrew packages stay installed; remove them with:
  brew uninstall wireguard-go wireguard-tools
NEXT
if is_dry_run; then
  log_info "(dry run: nothing was changed)"
fi
