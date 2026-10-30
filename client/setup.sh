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

Options:
  --config PATH           client config printed by server/peer.sh (required)
  --iface IFACE           physical interface allowed to reach the VPS; repeat for
                          several (default: auto, every en* hardware port,
                          re-read by the firewall daemon on every pass)
  --allow-internal-disk   install even though macOS runs from the internal disk
  --dry-run               print every command and file instead of changing anything
  --help                  show this help

Exit codes: 0 ok, 1 failure, 2 usage error.
USAGE
}

PEER_CONF=""
ALLOW_INTERNAL=0
IFACES=""
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

require_root

if is_dry_run; then
  log_info "Dry run: nothing will be changed. Commands and files are printed below."
fi

# ---------------------------------------------------------------- 1. boot disk

log_step "Checking the boot volume"
disk_rc=0
boot_volume_is_external || disk_rc=$?
if [ "${disk_rc}" -eq 0 ]; then
  log_ok "macOS is running from an external disk"
elif [ "${ALLOW_INTERNAL}" -eq 1 ]; then
  log_warn "macOS is not running from an external disk; continuing because of --allow-internal-disk"
else
  if [ "${disk_rc}" -eq 2 ]; then
    log_error "could not tell which disk macOS is running from (diskutil info / failed)."
  else
    log_error "this Mac is running macOS from its internal disk."
  fi
  cat >&2 <<MSG

oneexit is meant for a separate macOS installed on an external SSD that you
boot only when you need it. Setup installs a kill switch that blocks all
traffic except the WireGuard tunnel from the next boot on, before login.
On your everyday system that would cut off every app that is not meant to
go through your VPS, and it changes DNS and IPv6 for every network service.

diskutil info / reports:
$(boot_volume_summary)

If this really is what you want (a VM, a spare Mac), run again with
--allow-internal-disk. See docs/install-macos-external.md.
MSG
  exit 1
fi

log_step "Checking ${ONEEXIT_PF_CONF} for the com.apple anchor hook"
hook_rc=0
pf_conf_has_hook || hook_rc=$?
if [ "${hook_rc}" -eq 0 ]; then
  log_ok "${ONEEXIT_PF_CONF} evaluates anchor \"com.apple/*\""
elif [ "${hook_rc}" -eq 2 ] && is_dry_run; then
  log_warn "cannot read ${ONEEXIT_PF_CONF}; a real run would stop here"
else
  if [ "${hook_rc}" -eq 2 ]; then
    log_error "cannot read ${ONEEXIT_PF_CONF}."
  else
    log_error "${ONEEXIT_PF_CONF} has no 'anchor \"com.apple/*\"' line."
  fi
  cat >&2 <<MSG

oneexit never edits ${ONEEXIT_PF_CONF}. It loads its rules into the anchor
${ONEEXIT_ANCHOR}, and pf only evaluates that anchor when the main ruleset
contains the stock macOS hook:

    anchor "com.apple/*"

Without it the kill switch would load but block nothing. Restore the stock
${ONEEXIT_PF_CONF} (or add the line yourself) and run setup again.
MSG
  exit 1
fi

if command -v sw_vers >/dev/null 2>&1; then
  macos_version="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  macos_major="${macos_version%%.*}"
  if is_uint "${macos_major}" && [ "${macos_major}" -lt 13 ]; then
    die "macOS 13 or newer is required (found ${macos_version})"
  fi
else
  log_warn "sw_vers not found; this does not look like macOS"
fi

# ---------------------------------------------------------------- 2. Homebrew

log_step "Checking Homebrew"
BREW=""
for candidate in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
    BREW="${candidate}"
    break
  fi
done
if [ -z "${BREW}" ]; then
  if is_dry_run; then
    log_warn "Homebrew not found; a real run would stop here"
    BREW="brew"
  else
    log_error "Homebrew is required but was not found."
    cat >&2 <<'MSG'

Install it from https://brew.sh first (as your normal user, not with sudo):

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

then run this setup again.
MSG
    exit 1
  fi
else
  log_ok "Homebrew: ${BREW}"
fi

# Homebrew refuses to run as root; run it as the user who called sudo.
log_step "Installing wireguard-tools and wireguard-go"
if is_root && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  run sudo -u "${SUDO_USER}" -H "${BREW}" install wireguard-tools wireguard-go
elif is_root; then
  die "run setup with sudo from your normal admin account (Homebrew cannot run as root)"
else
  run "${BREW}" install wireguard-tools wireguard-go
fi

# ---------------------------------------------------------------- 3. peer config

log_step "Reading ${PEER_CONF}"
PARSED="$(parse_wg_conf "${PEER_CONF}")"
ENDPOINT_HOST="$(parsed_value "${PARSED}" ENDPOINT_HOST)"
ENDPOINT_PORT="$(parsed_value "${PARSED}" ENDPOINT_PORT)"
WG_ADDRESS="$(parsed_value "${PARSED}" ADDRESS)"
WG_DNS="$(parsed_value "${PARSED}" DNS)"
[ "$(parsed_value "${PARSED}" PRIVATE_KEY_PRESENT)" = "yes" ] ||
  die "${PEER_CONF} has no PrivateKey in [Interface]"
[ -n "${ENDPOINT_HOST}" ] || die "${PEER_CONF} has no Endpoint in [Peer]"
is_port "${ENDPOINT_PORT}" || die "Endpoint in ${PEER_CONF} needs a port (host:port), got \"${ENDPOINT_PORT}\""
[ -n "${WG_ADDRESS}" ] || log_warn "${PEER_CONF} has no Address in [Interface]"
case "${ENDPOINT_HOST}" in
  *:*) die "IPv6 endpoints are not supported (IPv6 is blocked entirely); use the server's IPv4 address" ;;
esac

# A previous setup (re-run after "uninstall --keep-keys" on the installed
# wg0.conf, which has no DNS line and a pinned Endpoint) keeps its values.
PREV_DNS=""
PREV_HOST=""
PREV_IP=""
if load_config; then
  PREV_DNS="${TUNNEL_DNS}"
  PREV_HOST="${VPS_HOST}"
  PREV_IP="${VPS_IP}"
fi

TUNNEL_DNS=""
for entry in $(printf '%s' "${WG_DNS}" | tr ',' ' '); do
  if is_ipv4 "${entry}"; then
    TUNNEL_DNS="${TUNNEL_DNS}${TUNNEL_DNS:+,}${entry}"
  fi
done
if [ -z "${TUNNEL_DNS}" ] && [ -n "${PREV_DNS}" ]; then
  log_ok "no DNS in ${PEER_CONF}; keeping ${PREV_DNS} from the previous setup"
  TUNNEL_DNS="${PREV_DNS}"
elif [ -z "${TUNNEL_DNS}" ]; then
  log_warn "no DNS in ${PEER_CONF}; using ${ONEEXIT_DEFAULT_DNS}"
  TUNNEL_DNS="${ONEEXIT_DEFAULT_DNS}"
fi

VPS_IP="$(resolve_host "${ENDPOINT_HOST}")" ||
  die "cannot resolve ${ENDPOINT_HOST}; use the server's IPv4 address in Endpoint"
VPS_PORT="${ENDPOINT_PORT}"
if [ "${VPS_IP}" != "${ENDPOINT_HOST}" ]; then
  log_ok "Endpoint ${ENDPOINT_HOST} resolved to ${VPS_IP} (stored; pf needs an IP)"
else
  log_ok "Endpoint ${VPS_IP}:${VPS_PORT}"
fi

VPS_HOST="${ENDPOINT_HOST}"
if [ "${VPS_IP}" = "${ENDPOINT_HOST}" ] && [ "${VPS_IP}" = "${PREV_IP}" ] && [ -n "${PREV_HOST}" ]; then
  VPS_HOST="${PREV_HOST}"
fi

# "auto": oneexit-firewalld re-reads the en* hardware ports on every pass,
# so an adapter plugged in later works. --iface pins the list.
if [ -z "${IFACES}" ]; then
  PHYS_IFACES="auto"
  log_ok "physical interfaces: auto (now: $(effective_phys_ifaces))"
else
  PHYS_IFACES="${IFACES}"
  log_ok "physical interfaces: ${PHYS_IFACES}"
fi

# ---------------------------------------------------------------- 4. files

log_step "Writing ${ONEEXIT_CONFIG}"
run mkdir -p "${ONEEXIT_ETC_DIR}"
write_file "${ONEEXIT_CONFIG}" 0644 <<CONF
# oneexit client configuration (written by setup.sh)
# Edit VPS_IP / VPS_PORT if the server moves; oneexit-firewalld re-renders the
# pf anchor from this file within a few seconds.
VPS_IP=${VPS_IP}
VPS_PORT=${VPS_PORT}
VPS_HOST=${VPS_HOST}
WG_IFACE_CONF=${ONEEXIT_WG_CONF}
PHYS_IFACES="${PHYS_IFACES}"
TUNNEL_DNS=${TUNNEL_DNS}
CONF

log_step "Installing the WireGuard config as ${ONEEXIT_WG_CONF}"
# wg-quick must not manage DNS (it restores its saved DNS on down and would
# undo portal/unlock; oneexit sets DNS itself), and the Endpoint is pinned to
# the IP because a hostname cannot be resolved once DNS points into the tunnel.
run install -d -m 0700 -o root -g wheel "${ONEEXIT_WG_DIR}"
render_installed_wg_conf "${PEER_CONF}" "${VPS_IP}" "${VPS_PORT}" |
  write_secret_file "${ONEEXIT_WG_CONF}" 0600
run chown root:wheel "${ONEEXIT_WG_CONF}"
log_ok "DNS line removed, Endpoint = ${VPS_IP}:${VPS_PORT}"

log_step "Installing the oneexit CLI and daemons"
run install -d -m 0755 -o root -g wheel "$(dirname "${ONEEXIT_BIN}")" "${ONEEXIT_LIBEXEC}" "${ONEEXIT_LIBEXEC}/lib"
run install -m 0755 -o root -g wheel "${SELF_DIR}/oneexit" "${ONEEXIT_BIN}"
run install -m 0755 -o root -g wheel "${SELF_DIR}/bin/oneexit-firewalld" "${ONEEXIT_LIBEXEC}/oneexit-firewalld"
run install -m 0755 -o root -g wheel "${SELF_DIR}/bin/oneexit-tunneld" "${ONEEXIT_LIBEXEC}/oneexit-tunneld"
run install -m 0755 -o root -g wheel "${SELF_DIR}/uninstall.sh" "${ONEEXIT_LIBEXEC}/uninstall.sh"
run install -m 0755 -o root -g wheel "${REPO_DIR}/scripts/leak-test.sh" "${ONEEXIT_LIBEXEC}/leak-test.sh"
for lib in common.sh pf.sh wgconf.sh; do
  run install -m 0644 -o root -g wheel "${LIB_DIR}/${lib}" "${ONEEXIT_LIBEXEC}/lib/${lib}"
done

log_step "Writing the pf anchor ${ONEEXIT_ANCHOR_FILE}"
# The tunnel is not up yet: the utun99 placeholder matches nothing, so only
# DHCP and the endpoint pass until oneexit-firewalld sees the real utun.
# shellcheck disable=SC2046 # the interface list is space-separated
render_pf "${VPS_IP}" "${VPS_PORT}" "${ONEEXIT_TUN_PLACEHOLDER}" $(effective_phys_ifaces) |
  write_file "${ONEEXIT_ANCHOR_FILE}" 0644

log_step "Recording the current pf state"
if [ -r "${ONEEXIT_STATE_FILE}" ]; then
  log_ok "keeping existing ${ONEEXIT_STATE_FILE} (setup ran before)"
else
  if pf_enabled; then
    pf_before="yes"
  else
    pf_before="no"
    if ! is_root; then
      log_info "    (pf status needs root to read; assuming it was disabled)"
    fi
  fi
  write_file "${ONEEXIT_STATE_FILE}" 0644 <<STATE
# Written once by setup.sh; read by uninstall.sh.
PF_WAS_ENABLED=${pf_before}
SETUP_EPOCH=$(now_epoch)
STATE
fi

# ---------------------------------------------------------------- 5. network services

log_step "Turning IPv6 off and setting DNS to ${TUNNEL_DNS} on every network service"
services="$(network_services)"
if [ -z "${services}" ]; then
  log_warn "no network services found (networksetup missing?)"
fi
while IFS= read -r service; do
  [ -n "${service}" ] || continue
  run networksetup -setv6off "${service}" || log_warn "could not turn IPv6 off on \"${service}\""
done <<EOT
${services}
EOT
# shellcheck disable=SC2046 # TUNNEL_DNS may hold several servers
set_dns_all $(printf '%s' "${TUNNEL_DNS}" | tr ',' ' ')

# ---------------------------------------------------------------- 6. launchd

log_step "Installing launchd daemons"
run mkdir -p "${ONEEXIT_LOG_DIR}" "${ONEEXIT_RUN_DIR}"
for label in "${ONEEXIT_FIREWALL_LABEL}" "${ONEEXIT_TUNNEL_LABEL}"; do
  plist="${ONEEXIT_LAUNCHD_DIR}/${label}.plist"
  write_file "${plist}" 0644 <"${SELF_DIR}/launchd/${label}.plist"
  run chown root:wheel "${plist}"
done

log_step "Rotating the logs (newsyslog)"
# The daemons reopen their log on SIGUSR1 (30), sent via their pid files.
write_file "${ONEEXIT_NEWSYSLOG_CONF}" 0644 <<NEWSYSLOG
# oneexit logs: rotate at 1 MB, keep 5 (written by oneexit setup.sh)
# logfilename                      [owner:group] mode count size(KB) when flags pid_file                           sig
${ONEEXIT_LOG_DIR}/firewall.log    root:wheel    644  5     1024     *    -     ${ONEEXIT_RUN_DIR}/firewalld.pid    30
${ONEEXIT_LOG_DIR}/tunnel.log      root:wheel    644  5     1024     *    -     ${ONEEXIT_RUN_DIR}/tunneld.pid      30
NEWSYSLOG

log_step "Starting the daemons"
for label in "${ONEEXIT_FIREWALL_LABEL}" "${ONEEXIT_TUNNEL_LABEL}"; do
  if command -v launchctl >/dev/null 2>&1 && launchctl print "system/${label}" >/dev/null 2>&1; then
    run launchctl bootout "system/${label}" || true
  fi
  # wireguard-go outlives its daemon (AbandonProcessGroup); on a re-run take
  # the old tunnel down so the new daemon starts it from the new wg0.conf.
  if [ "${label}" = "${ONEEXIT_TUNNEL_LABEL}" ] && wg_tunnel_up; then
    run wg-quick down "${ONEEXIT_WG_CONF}" || log_warn "wg-quick down failed"
  fi
  run launchctl enable "system/${label}"
  # Right after a bootout launchd can answer "Bootstrap failed: 5"; retry.
  attempt=1
  until run launchctl bootstrap system "${ONEEXIT_LAUNCHD_DIR}/${label}.plist"; do
    if [ "${attempt}" -ge 5 ]; then
      die "launchctl bootstrap ${label} failed ${attempt} times; see: sudo launchctl print system/${label}"
    fi
    log_warn "launchctl bootstrap ${label} failed; retrying (${attempt}/5)"
    attempt=$((attempt + 1))
    sleep 1
  done
done

# ---------------------------------------------------------------- 7. next steps

log_step "Done"
cat <<NEXT

The kill switch is active: only UDP to ${VPS_IP}:${VPS_PORT} and DHCP leave the
physical interfaces; everything else must go through the WireGuard tunnel.

Next steps:
  oneexit status              pf, tunnel and handshake at a glance
  sudo oneexit leak-test      check IPv4, IPv6, DNS and direct-interface leaks
  sudo oneexit portal         3 minutes to log in to a hotel or airport captive portal
  sudo oneexit doctor         full diagnostics if something does not work

Logs: ${ONEEXIT_LOG_DIR}/firewall.log and tunnel.log (oneexit logs).
Undo everything: sudo oneexit uninstall
NEXT
if is_dry_run; then
  log_info "(dry run: nothing was changed)"
fi
