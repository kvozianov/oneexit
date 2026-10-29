#!/usr/bin/env bash
# oneexit server installer: WireGuard + unbound + nftables on Debian/Ubuntu.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/wg.sh
source "${SCRIPT_DIR}/lib/wg.sh"
# shellcheck source=lib/templates.sh
source "${SCRIPT_DIR}/lib/templates.sh"

usage() {
  cat <<'USAGE'
Usage: install.sh [--port N] [--endpoint HOST_OR_IP] [--peer NAME] [--dry-run]

Turn a fresh Debian 12+ / Ubuntu 22.04+ VPS into the single exit of a oneexit
Mac: WireGuard on wg0 (10.66.0.1/24), NAT to the internet, and a recursive
DNS resolver (unbound) reachable only through the tunnel. Must run as root.

Options:
  --port N                WireGuard UDP port (default 51820; 443 helps on
                          restrictive networks)
  --endpoint HOST_OR_IP   address clients connect to (default: detected public IP)
  --peer NAME             name of the first peer (default: mac)
  --dry-run               print every command and file instead of changing anything
  -h, --help              show this help

The tunnel carries DNS to 10.66.0.1 and all IPv4 traffic. Re-running is safe:
existing keys, wg0.conf and peers are kept.
Exit codes: 0 ok, 1 failure, 2 usage error.
USAGE
}

usage_error() {
  error "$*"
  printf 'See: install.sh --help\n' >&2
  exit 2
}

PORT="51820"
PORT_SET=0
ENDPOINT=""
PEER="mac"

WG_DIR="$(root_path /etc/wireguard)"
WG_CONF="${WG_DIR}/wg0.conf"
PEERS_DIR="${WG_DIR}/peers"
STATE_FILE="${WG_DIR}/oneexit.env"
SYSCTL_FILE="$(root_path /etc/sysctl.d/99-oneexit.conf)"
UNBOUND_DIR="$(root_path /etc/unbound)"
UNBOUND_FILE="${UNBOUND_DIR}/unbound.conf.d/oneexit.conf"

# nftables persistence: our ruleset lives in its own file
# (/etc/nftables.d/oneexit.nft: only the tables inet oneexit and
# ip oneexit_nat, safe to load repeatedly) and is loaded by our own oneshot
# unit, oneexit-nft.service, at boot and by this installer. /etc/nftables.conf
# and nftables.service are left alone on purpose: the stock
# /etc/nftables.conf starts with `flush ruleset`, which would wipe rules of
# other tools (ufw, docker) at every boot or restart of nftables.service.
# Stopping oneexit-nft.service deletes our two tables and nothing else.
NFT_RULES_PATH="/etc/nftables.d/oneexit.nft"
NFT_FILE="$(root_path "${NFT_RULES_PATH}")"
NFT_UNIT="oneexit-nft.service"
NFT_UNIT_FILE="$(root_path "/etc/systemd/system/${NFT_UNIT}")"
# Earlier versions appended these two lines to /etc/nftables.conf; they are
# removed if present.
NFT_MAIN="$(root_path /etc/nftables.conf)"
NFT_OLD_INCLUDE="include \"${NFT_RULES_PATH}\""
NFT_OLD_COMMENT="# oneexit (server/install.sh): WireGuard firewall and NAT"

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --port)
        (($# >= 2)) || usage_error "--port needs a value"
        PORT="$2"
        PORT_SET=1
        shift
        ;;
      --port=*)
        PORT="${1#*=}"
        PORT_SET=1
        ;;
      --endpoint)
        (($# >= 2)) || usage_error "--endpoint needs a value"
        ENDPOINT="$2"
        shift
        ;;
      --endpoint=*) ENDPOINT="${1#*=}" ;;
      --peer)
        (($# >= 2)) || usage_error "--peer needs a value"
        PEER="$2"
        shift
        ;;
      --peer=*) PEER="${1#*=}" ;;
      --dns-only-tunnel) ;; # implied: DNS always goes to 10.66.0.1 through the tunnel
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_error "unknown argument: $1" ;;
    esac
    shift
  done
  valid_port "${PORT}" || usage_error "invalid --port: ${PORT} (1-65535)"
  if [[ -n "${ENDPOINT}" ]] && ! valid_endpoint "${ENDPOINT}"; then
    usage_error "invalid --endpoint: ${ENDPOINT} (hostname or IPv4 address)"
  fi
  valid_peer_name "${PEER}" || usage_error "invalid --peer: ${PEER} (letters, digits, '-', '_'; max 32)"
}

check_system() {
  local os
  step "Checking the system"
  if os="$(detect_os)"; then
    ok "${os}"
  elif is_dry_run; then
    warn "dry-run: continuing although this OS is not supported"
  else
    exit 1
  fi
  require_root
}

install_packages() {
  step "Installing packages"
  # On a fresh VPS unattended-upgrades often holds the dpkg lock for a few
  # minutes: wait for it instead of failing. NEEDRESTART_MODE=a keeps Ubuntu's
  # needrestart from prompting.
  run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o DPkg::Lock::Timeout=600 update -q
  run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o DPkg::Lock::Timeout=600 install -y -q \
    wireguard wireguard-tools unbound nftables qrencode
  if ! is_dry_run; then
    require_cmd wg wg-quick nft unbound-checkconf qrencode systemctl sysctl ip
  fi
  ok "packages ready"
}

resolve_settings() {
  local existing_port=""
  step "Network settings"
  IFACE="$(default_iface)" || exit 1
  read_state "${STATE_FILE}"

  if [[ -r "${WG_CONF}" ]]; then
    existing_port="$(awk -F= '/^[ \t]*ListenPort[ \t]*=/ { gsub(/[ \t\r]/, "", $2); print $2; exit }' "${WG_CONF}")"
  elif [[ -e "${WG_CONF}" ]]; then
    existing_port="${STATE_PORT}"
  fi
  if [[ -n "${existing_port}" && "${existing_port}" != "${PORT}" ]]; then
    if ((PORT_SET)); then
      die "${WG_CONF} already uses ListenPort ${existing_port}; to change the port, edit it (and every client config) or remove it and re-run"
    fi
    PORT="${existing_port}"
    ok "keeping the existing port ${PORT}"
  fi

  if [[ -z "${ENDPOINT}" && -n "${STATE_ENDPOINT}" ]]; then
    ENDPOINT="${STATE_ENDPOINT}"
    ok "using the endpoint from ${STATE_FILE}"
  elif [[ -z "${ENDPOINT}" ]]; then
    if is_dry_run; then
      warn "dry-run: not detecting the public IP; using ${DRYRUN_ENDPOINT} (pass --endpoint)"
    fi
    ENDPOINT="$(public_ip)" || exit 1
  elif [[ -n "${STATE_ENDPOINT}" && "${STATE_ENDPOINT}" != "${ENDPOINT}" ]]; then
    warn "endpoint changed from ${STATE_ENDPOINT} to ${ENDPOINT}; existing client configs still use the old one"
  fi
  ok "endpoint ${ENDPOINT}:${PORT}/udp, outgoing interface ${IFACE}"
}

setup_keys() {
  step "WireGuard keys"
  run install -d -m 0700 "${WG_DIR}" "${PEERS_DIR}"
  if [[ -s "${WG_DIR}/server.key" && -r "${WG_DIR}/server.key" ]]; then
    SERVER_PRIVKEY="$(tr -d '[:space:]' <"${WG_DIR}/server.key")"
    if [[ ! -s "${WG_DIR}/server.pub" ]]; then
      if is_dry_run; then
        SERVER_PUBKEY="DRYRUN_SERVER_PUBLIC_KEY"
      else
        SERVER_PUBKEY="$(printf '%s\n' "${SERVER_PRIVKEY}" | wg pubkey)"
      fi
      printf '%s\n' "${SERVER_PUBKEY}" | write_file "${WG_DIR}/server.pub" 0644
    fi
    ok "keeping the existing server key"
  elif [[ -e "${WG_DIR}/server.key" ]]; then
    is_dry_run || die "cannot read ${WG_DIR}/server.key"
    SERVER_PRIVKEY="DRYRUN_SERVER_PRIVATE_KEY"
    warn "dry-run: cannot read ${WG_DIR}/server.key; it would be kept"
  else
    if is_dry_run; then
      # Same placeholder peer.sh uses for the server key in dry-run.
      SERVER_PRIVKEY="DRYRUN_SERVER_PRIVATE_KEY"
      SERVER_PUBKEY="DRYRUN_SERVER_PUBLIC_KEY"
    else
      gen_keys
      SERVER_PRIVKEY="${WG_PRIVKEY}"
      SERVER_PUBKEY="${WG_PUBKEY}"
    fi
    printf '%s\n' "${SERVER_PRIVKEY}" | write_file "${WG_DIR}/server.key" 0600
    printf '%s\n' "${SERVER_PUBKEY}" | write_file "${WG_DIR}/server.pub" 0644
  fi
}

setup_wireguard() {
  step "WireGuard interface wg0"
  WG_CONF_NEW=0
  if [[ -e "${WG_CONF}" ]]; then
    ok "keeping the existing ${WG_CONF} (keys and peers preserved)"
  else
    render_server_conf "${PORT}" "${SERVER_PRIVKEY}" | write_file "${WG_CONF}" 0600
    WG_CONF_NEW=1
  fi
  printf 'ENDPOINT=%s\nPORT=%s\n' "${ENDPOINT}" "${PORT}" | write_file "${STATE_FILE}" 0600
}

setup_sysctl() {
  step "IP forwarding"
  render_sysctl_conf | write_file "${SYSCTL_FILE}" 0644
  run sysctl -p "${SYSCTL_FILE}"
}

# Remove the include line an earlier version added to /etc/nftables.conf
# (idempotent: nothing happens when it is absent).
remove_old_nft_include() {
  local content
  [[ -e "${NFT_MAIN}" ]] || return 0
  if [[ ! -r "${NFT_MAIN}" ]]; then
    is_dry_run || die "cannot read ${NFT_MAIN}"
    warn "dry-run: cannot read ${NFT_MAIN}; an old oneexit include line in it would be removed"
    return 0
  fi
  grep -qxF "${NFT_OLD_INCLUDE}" "${NFT_MAIN}" || return 0
  content="$(awk -v inc="${NFT_OLD_INCLUDE}" -v cmt="${NFT_OLD_COMMENT}" '$0 != inc && $0 != cmt' "${NFT_MAIN}")"
  printf '%s\n' "${content}" | write_file "${NFT_MAIN}" 0755
  ok "removed the old oneexit include line from ${NFT_MAIN}"
}

# With ufw active, its own base chains drop what ours accept (a packet must be
# accepted by every base chain), so open the same holes through ufw.
configure_ufw() {
  local status
  command -v ufw >/dev/null 2>&1 || return 0
  status="$(ufw status 2>/dev/null || true)"
  if grep -q '^Status: active' <<<"${status}"; then
    warn "ufw is active; adding matching ufw rules"
    run ufw allow "${PORT}/udp"
    run ufw allow in on wg0 from "${WG_SUBNET}" to "${WG_SERVER_IP}" port 53
    run ufw route allow in on wg0 out on "${IFACE}"
  fi
}

setup_nftables() {
  step "nftables (NAT ${WG_SUBNET} -> ${IFACE}, allow udp/${PORT})"
  run install -d -m 0755 "$(dirname "${NFT_FILE}")"
  local was_active=0
  render_nftables_conf "${PORT}" "${IFACE}" | write_file "${NFT_FILE}" 0644
  render_nft_unit | write_file "${NFT_UNIT_FILE}" 0644
  remove_old_nft_include
  if ! is_dry_run && systemctl is-active --quiet "${NFT_UNIT}"; then
    was_active=1
  fi
  run systemctl daemon-reload
  run systemctl enable --now "${NFT_UNIT}"
  if ((was_active)); then
    # Already running: reload the (possibly changed) ruleset atomically.
    run nft -f "${NFT_FILE}"
  fi
  configure_ufw
}

distro_sets_trust_anchor() {
  local f
  for f in "${UNBOUND_DIR}/unbound.conf" "${UNBOUND_DIR}"/unbound.conf.d/*.conf; do
    [[ "${f}" == "${UNBOUND_FILE}" ]] && continue
    [[ -r "${f}" ]] || continue
    grep -Eq '^[[:space:]]*auto-trust-anchor-file:' "${f}" && return 0
  done
  return 1
}

# unbound binds 10.66.0.1 only, so it never competes with systemd-resolved
# (127.0.0.53:53) for port 53. Because no loopback address is configured,
# Debian's unbound-resolvconf helper does not point the host resolver at it.
setup_unbound() {
  local anchor="yes"
  step "unbound (recursive DNS on ${WG_SERVER_IP}:53, tunnel only)"
  if distro_sets_trust_anchor; then
    anchor="no"
  fi
  render_unbound_conf "${anchor}" | write_file "${UNBOUND_FILE}" 0644
  # unbound-checkconf fails while the trust anchor file does not exist yet;
  # the unbound service creates it on start (unbound-anchor).
  if is_dry_run || [[ -e /var/lib/unbound/root.key ]]; then
    run unbound-checkconf
  else
    warn "skipping unbound-checkconf: /var/lib/unbound/root.key is created when unbound starts"
  fi
}

start_services() {
  step "Services"
  if ((WG_CONF_NEW)) && ! is_dry_run && systemctl is-active --quiet wg-quick@wg0; then
    run systemctl restart wg-quick@wg0
  fi
  run systemctl enable --now wg-quick@wg0
  run systemctl enable unbound
  run systemctl restart unbound
  ok "wg-quick@wg0, unbound and ${NFT_UNIT} enabled"
}

first_peer() {
  local conf="${PEERS_DIR}/${PEER}.conf"
  local -a dry=()
  step "First peer: ${PEER}"
  is_dry_run && dry=(--dry-run)
  if [[ -e "${conf}" ]]; then
    ok "peer ${PEER} already exists; keeping it"
    if [[ -r "${conf}" ]]; then
      cat "${conf}"
    fi
  elif [[ -r "${WG_CONF}" ]] && peer_pubkey_from_conf "${WG_CONF}" "${PEER}" >/dev/null; then
    warn "peer ${PEER} is in ${WG_CONF} but ${conf} is missing; run: peer.sh revoke ${PEER} && peer.sh add ${PEER}"
    return 0
  else
    "${SCRIPT_DIR}/peer.sh" add "${PEER}" --endpoint "${ENDPOINT}" --port "${PORT}" ${dry[@]+"${dry[@]}"}
  fi
  printf '\n'
  run qrencode -t ansiutf8 -r "${conf}"
}

summary() {
  step "Done"
  cat >&2 <<SUMMARY

  Endpoint      ${ENDPOINT}:${PORT}/udp
  Tunnel        wg0 ${WG_SERVER_IP}/24, NAT out of ${IFACE}
  DNS           unbound on ${WG_SERVER_IP}:53 (reachable through the tunnel only)
  First peer    ${PEERS_DIR}/${PEER}.conf

Next steps:
  1. Allow UDP ${PORT} in your VPS provider's firewall, if it has one.
  2. Copy the peer config to the Mac, e.g.:
       scp root@${ENDPOINT}:${PEERS_DIR}/${PEER}.conf ./${PEER}.conf
     and run: client/setup.sh --config ${PEER}.conf
  3. More devices: ${SCRIPT_DIR}/peer.sh add NAME   (list | qr NAME | revoke NAME)
SUMMARY
  if is_dry_run; then
    printf '\ndry-run: nothing was changed.\n' >&2
  fi
}

main() {
  parse_args "$@"
  if ! is_dry_run; then
    umask 077
  fi
  check_system
  install_packages
  resolve_settings
  setup_keys
  setup_wireguard
  setup_sysctl
  setup_nftables
  setup_unbound
  start_services
  first_peer
  summary
}

main "$@"
