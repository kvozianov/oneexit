#!/usr/bin/env bash
# Manage WireGuard peers of a oneexit server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/wg.sh
source "${SCRIPT_DIR}/lib/wg.sh"

usage() {
  cat <<'USAGE'
Usage: peer.sh [options] COMMAND [NAME]

Manage WireGuard peers (clients) of the oneexit server.

Commands:
  add NAME      create a peer: keys, next free 10.66.0.N address, [Peer] section
                in /etc/wireguard/wg0.conf (applied live), client config saved to
                /etc/wireguard/peers/NAME.conf and printed to stdout
  revoke NAME   remove the peer from wg0.conf and the running interface, and
                delete its saved client config
  qr NAME       print the client config of NAME as a QR code
  list          list peers (name, address, public key)

Options:
  --endpoint HOST_OR_IP   endpoint written into client configs
                          (default: ENDPOINT from /etc/wireguard/oneexit.env)
  --port N                server UDP port written into client configs
                          (default: PORT from /etc/wireguard/oneexit.env)
  --dry-run               print commands and file contents, change nothing
  -h, --help              show this help

NAME: letters, digits, '-' and '_', up to 32 characters.
Exit codes: 0 ok, 1 failure, 2 usage error.
USAGE
}

usage_error() {
  error "$*"
  printf 'See: peer.sh --help\n' >&2
  exit 2
}

WG_DIR="$(root_path /etc/wireguard)"
WG_CONF="${WG_DIR}/wg0.conf"
PEERS_DIR="${WG_DIR}/peers"
STATE_FILE="${WG_DIR}/oneexit.env"

OPT_ENDPOINT=""
OPT_PORT=""

# Serialise concurrent add/revoke runs (Linux, real mode only).
take_lock() {
  is_dry_run && return 0
  command -v flock >/dev/null 2>&1 || return 0
  mkdir -p "${WG_DIR}"
  exec 9>"${WG_DIR}/.peer.lock"
  flock -w 30 9 || die "another peer.sh is running (lock ${WG_DIR}/.peer.lock)"
}

# Interface is up and can be changed live (always assumed in dry-run).
wg0_live() {
  is_dry_run && return 0
  wg show wg0 >/dev/null 2>&1
}

resolve_endpoint_port() {
  read_state "${STATE_FILE}"
  ENDPOINT="${OPT_ENDPOINT:-${STATE_ENDPOINT}}"
  PORT="${OPT_PORT:-${STATE_PORT}}"
  if [[ -z "${ENDPOINT}" ]]; then
    is_dry_run || die "no endpoint: ${STATE_FILE} is missing; run install.sh or pass --endpoint"
    ENDPOINT="${DRYRUN_ENDPOINT}"
  fi
  if [[ -z "${PORT}" ]]; then
    is_dry_run || die "no port: ${STATE_FILE} is missing; run install.sh or pass --port"
    PORT="51820"
  fi
  valid_endpoint "${ENDPOINT}" || die "invalid endpoint: ${ENDPOINT}"
  valid_port "${PORT}" || die "invalid port: ${PORT}"
}

server_pubkey() {
  if [[ -r "${WG_DIR}/server.pub" ]]; then
    tr -d '[:space:]' <"${WG_DIR}/server.pub"
    printf '\n'
  elif ! is_dry_run && [[ -r "${WG_DIR}/server.key" ]]; then
    wg pubkey <"${WG_DIR}/server.key"
  elif is_dry_run; then
    printf 'DRYRUN_SERVER_PUBLIC_KEY\n'
  else
    die "server public key not found in ${WG_DIR}; run install.sh first"
  fi
}

peer_exists() {
  local name="$1"
  [[ -e "${PEERS_DIR}/${name}.conf" ]] && return 0
  [[ -r "${WG_CONF}" ]] && peer_pubkey_from_conf "${WG_CONF}" "${name}" >/dev/null
}

check_name() {
  [[ -n "${1:-}" ]] || usage_error "missing NAME"
  valid_peer_name "$1" || usage_error "invalid NAME '$1' (letters, digits, '-', '_'; max 32)"
}

cmd_add() {
  local name="$1" ip srv_pub priv pub existing="" section config
  check_name "${name}"
  require_root
  is_dry_run || require_cmd wg
  take_lock
  if ! is_dry_run && [[ ! -f "${WG_CONF}" ]]; then
    die "${WG_CONF} not found; run install.sh first"
  fi
  if peer_exists "${name}"; then
    die "peer '${name}' already exists (show it: cat ${PEERS_DIR}/${name}.conf; replace it: peer.sh revoke ${name} first)"
  fi
  if [[ -e "${WG_CONF}" && ! -r "${WG_CONF}" ]]; then
    warn "cannot read ${WG_CONF} (not root?); the address shown may already be taken"
  fi
  resolve_endpoint_port
  srv_pub="$(server_pubkey)"
  ip="$(next_peer_ip "${WG_CONF}")" || die "no free address left in ${WG_SUBNET}"
  gen_keys
  priv="${WG_PRIVKEY}"
  pub="${WG_PUBKEY}"

  step "Adding peer ${name} (${ip})"
  section="$(render_peer_section "${name}" "${pub}" "${ip}")"
  if [[ -r "${WG_CONF}" ]]; then
    existing="$(cat "${WG_CONF}")"
  fi
  if [[ -n "${existing}" ]]; then
    printf '%s\n\n%s\n' "${existing}" "${section}" | write_file "${WG_CONF}" 0600
  elif is_dry_run; then
    # No wg0.conf yet (e.g. inside install.sh --dry-run): show the addition.
    printf '[dry-run] append to %s:\n%s\n' "${WG_CONF}" "${section}"
  else
    printf '%s\n' "${section}" | write_file "${WG_CONF}" 0600
  fi

  if wg0_live; then
    run wg set wg0 peer "${pub}" allowed-ips "${ip}/32"
  else
    warn "wg0 is not up; the peer becomes active when wg-quick@wg0 starts"
  fi

  if is_dry_run || [[ ! -d "${PEERS_DIR}" ]]; then
    run install -d -m 0700 "${PEERS_DIR}"
  fi
  config="$(render_peer_conf "${priv}" "${ip}" "${srv_pub}" "${ENDPOINT}" "${PORT}")"
  printf '%s\n' "${config}" | write_file "${PEERS_DIR}/${name}.conf" 0600
  printf '%s\n' "${pub}" | write_file "${PEERS_DIR}/${name}.pub" 0644
  ok "peer ${name}: ${ip}, endpoint ${ENDPOINT}:${PORT}; config saved to ${PEERS_DIR}/${name}.conf"
  printf '%s\n' "${config}"
}

cmd_revoke() {
  local name="$1" pub="" new
  check_name "${name}"
  require_root
  is_dry_run || require_cmd wg
  take_lock
  [[ -r "${WG_CONF}" ]] || die "cannot read ${WG_CONF} (run install.sh first, as root)"
  if ! pub="$(peer_pubkey_from_conf "${WG_CONF}" "${name}")"; then
    if [[ -r "${PEERS_DIR}/${name}.pub" ]]; then
      pub="$(tr -d '[:space:]' <"${PEERS_DIR}/${name}.pub")"
    else
      die "no such peer: ${name}"
    fi
  fi

  step "Revoking peer ${name}"
  new="$(remove_peer_section "${name}" <"${WG_CONF}")"
  printf '%s\n' "${new}" | write_file "${WG_CONF}" 0600
  if [[ -n "${pub}" && "${pub}" != "-" ]] && wg0_live; then
    run wg set wg0 peer "${pub}" remove
  fi
  run rm -f "${PEERS_DIR}/${name}.conf" "${PEERS_DIR}/${name}.pub"
  ok "peer ${name} revoked"
}

cmd_qr() {
  local name="$1" file
  check_name "${name}"
  file="${PEERS_DIR}/${name}.conf"
  if ! is_dry_run; then
    [[ -r "${file}" ]] || die "cannot read ${file} (no such peer, or not root)"
    require_cmd qrencode
  fi
  run qrencode -t ansiutf8 -r "${file}"
}

cmd_list() {
  local rows n=0 name ip pub
  [[ -r "${WG_CONF}" ]] || die "cannot read ${WG_CONF} (run install.sh first, as root)"
  rows="$(list_peers "${WG_CONF}")"
  printf '%-32s %-15s %s\n' "NAME" "ADDRESS" "PUBLIC KEY"
  while IFS=$'\t' read -r name ip pub; do
    [[ -n "${name}" ]] || continue
    printf '%-32s %-15s %s\n' "${name}" "${ip}" "${pub}"
    n=$((n + 1))
  done <<<"${rows}"
  ok "${n} peer(s)"
}

main() {
  local -a args=()
  while (($# > 0)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --endpoint)
        (($# >= 2)) || usage_error "--endpoint needs a value"
        OPT_ENDPOINT="$2"
        shift
        ;;
      --endpoint=*) OPT_ENDPOINT="${1#*=}" ;;
      --port)
        (($# >= 2)) || usage_error "--port needs a value"
        OPT_PORT="$2"
        shift
        ;;
      --port=*) OPT_PORT="${1#*=}" ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        while (($# > 0)); do
          args+=("$1")
          shift
        done
        break
        ;;
      -*) usage_error "unknown option: $1" ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  if [[ -n "${OPT_ENDPOINT}" ]] && ! valid_endpoint "${OPT_ENDPOINT}"; then
    usage_error "invalid --endpoint: ${OPT_ENDPOINT}"
  fi
  if [[ -n "${OPT_PORT}" ]] && ! valid_port "${OPT_PORT}"; then
    usage_error "invalid --port: ${OPT_PORT} (1-65535)"
  fi
  ((${#args[@]} > 0)) || usage_error "missing COMMAND"

  local cmd="${args[0]}" name="${args[1]:-}"
  case "${cmd}" in
    add | revoke | qr)
      ((${#args[@]} <= 2)) || usage_error "too many arguments"
      "cmd_${cmd}" "${name}"
      ;;
    list)
      ((${#args[@]} == 1)) || usage_error "too many arguments"
      cmd_list
      ;;
    *) usage_error "unknown command: ${cmd}" ;;
  esac
}

main "$@"
