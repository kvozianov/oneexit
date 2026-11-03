#!/usr/bin/env bash
# oneexit client setup: turn a fresh macOS on an external SSD into a
# tunnel-only machine (pf kill switch + WireGuard, both started by launchd).
set -euo pipefail

_self="${BASH_SOURCE[0]}"
while [ -h "${_self}" ]; do
  _dir="$(cd -P "$(dirname "${_self}")" && pwd)"
  _self="$(readlink "${_self}")"
  case "${_self}" in /*) ;; *) _self="${_dir}/${_self}" ;; esac
done
SELF_DIR="$(cd -P "$(dirname "${_self}")" && pwd)"
REPO_DIR="$(cd -P "${SELF_DIR}/.." && pwd)"
LIB_DIR="${SELF_DIR}/lib"
# shellcheck source=lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=lib/pf.sh
. "${LIB_DIR}/pf.sh"
# shellcheck source=lib/wgconf.sh
. "${LIB_DIR}/wgconf.sh"
# shellcheck source=lib/privacy.sh
. "${LIB_DIR}/privacy.sh"
# shellcheck source=lib/setup_steps.sh
. "${LIB_DIR}/setup_steps.sh"

usage() {
  cat <<USAGE
Usage: sudo client/setup.sh --config PEER.conf [options]

Sets up the oneexit kill switch on this Mac:
  * installs wireguard-tools and wireguard-go with Homebrew
  * stores the WireGuard client config as ${ONEEXIT_WG_CONF} (without its DNS
    line, Endpoint pinned to the server's IP)
  * writes the pf anchor ${ONEEXIT_ANCHOR_FILE} (only the tunnel may talk)
  * turns IPv6 off and points DNS at the tunnel resolver on every network service
  * installs and starts the launchd daemons ${ONEEXIT_FIREWALL_LABEL} and ${ONEEXIT_TUNNEL_LABEL}
  * hardens macOS (oneexit harden): Location Services off, time zone and region
    of the exit country, generic computer name, no LAN address in WebRTC

Options:
  --config PATH           client config printed by server/peer.sh (required)
  --iface IFACE           physical interface allowed to reach the VPS; repeat for
                          several (default: auto, every en* hardware port,
                          re-read by the firewall daemon on every pass)
  --timezone TZ           time zone of the exit country, e.g. Europe/Berlin
                          (default: the "# oneexit-timezone = TZ" line of the
                          peer config, else ${PRIVACY_DEFAULT_TIMEZONE})
  --region RR             two-letter region for the locale, e.g. DE (default:
                          the country of the time zone, else ${PRIVACY_DEFAULT_REGION})
  --no-harden             do not change Location Services, time zone, region,
                          computer name or browser settings (TIMEZONE and REGION
                          are still stored for a later "oneexit harden")
  --allow-internal-disk   install even though macOS runs from the internal disk
  --dry-run               print every command and file instead of changing anything
  --help                  show this help

Exit codes: 0 ok, 1 failure, 2 usage error.
USAGE
}

PEER_CONF=""
ALLOW_INTERNAL=0
IFACES=""
TIMEZONE=""
REGION=""
NO_HARDEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      [ "$#" -ge 2 ] || usage_error "--config needs a path"
      PEER_CONF="$2"
      shift
      ;;
    --config=*) PEER_CONF="${1#--config=}" ;;
    --iface)
      [ "$#" -ge 2 ] || usage_error "--iface needs an interface name"
      is_iface_name "$2" || usage_error "invalid interface name: $2"
      IFACES="${IFACES}${IFACES:+ }$2"
      shift
      ;;
    --iface=*)
      is_iface_name "${1#--iface=}" || usage_error "invalid interface name: ${1#--iface=}"
      IFACES="${IFACES}${IFACES:+ }${1#--iface=}"
      ;;
    --timezone)
      [ "$#" -ge 2 ] || usage_error "--timezone needs a value"
      TIMEZONE="$2"
      shift
      ;;
    --timezone=*) TIMEZONE="${1#--timezone=}" ;;
    --region)
      [ "$#" -ge 2 ] || usage_error "--region needs a value"
      REGION="$2"
      shift
      ;;
    --region=*) REGION="${1#--region=}" ;;
    --no-harden) NO_HARDEN=1 ;;
    --allow-internal-disk) ALLOW_INTERNAL=1 ;;
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

[ -n "${PEER_CONF}" ] || {
  log_error "--config is required"
  usage >&2
  exit 2
}
[ -r "${PEER_CONF}" ] || die "cannot read ${PEER_CONF}"
setup_validate_options

require_root

if is_dry_run; then
  log_info "Dry run: nothing will be changed. Commands and files are printed below."
fi

# The steps live in lib/setup_steps.sh ("oneexit init" runs the same ones).
setup_preflight
setup_client
setup_harden
setup_next_steps
