# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# oneexit client: shared helpers (logging, dry-run, paths, system probes).
# Sourced by setup.sh, uninstall.sh, the oneexit CLI, the daemons and leak-test.sh.
# Must stay compatible with the stock macOS bash 3.2.

ONEEXIT_VERSION="0.1.1"
ONEEXIT_ANCHOR="com.apple/oneexit"

DRY_RUN="${DRY_RUN:-0}"

# Install locations. Every path can be overridden from the environment so the
# test suite can point the scripts at a temporary directory.
ONEEXIT_ETC_DIR="${ONEEXIT_ETC_DIR:-/usr/local/etc/oneexit}"
ONEEXIT_CONFIG="${ONEEXIT_CONFIG:-${ONEEXIT_ETC_DIR}/config}"
ONEEXIT_STATE_FILE="${ONEEXIT_STATE_FILE:-${ONEEXIT_ETC_DIR}/state}"
ONEEXIT_WG_DIR="${ONEEXIT_WG_DIR:-/usr/local/etc/wireguard}"
ONEEXIT_WG_CONF="${ONEEXIT_WG_CONF:-${ONEEXIT_WG_DIR}/wg0.conf}"
ONEEXIT_ANCHOR_FILE="${ONEEXIT_ANCHOR_FILE:-/etc/pf.anchors/com.oneexit}"
ONEEXIT_BIN="${ONEEXIT_BIN:-/usr/local/bin/oneexit}"
ONEEXIT_LIBEXEC="${ONEEXIT_LIBEXEC:-/usr/local/libexec/oneexit}"
ONEEXIT_LAUNCHD_DIR="${ONEEXIT_LAUNCHD_DIR:-/Library/LaunchDaemons}"
ONEEXIT_LOG_DIR="${ONEEXIT_LOG_DIR:-/var/log/oneexit}"
ONEEXIT_RUN_DIR="${ONEEXIT_RUN_DIR:-/var/run/oneexit}"
ONEEXIT_WG_RUN_DIR="${ONEEXIT_WG_RUN_DIR:-/var/run/wireguard}"
ONEEXIT_PF_CONF="${ONEEXIT_PF_CONF:-/etc/pf.conf}"
ONEEXIT_NEWSYSLOG_CONF="${ONEEXIT_NEWSYSLOG_CONF:-/etc/newsyslog.d/oneexit.conf}"
ONEEXIT_TUN_PLACEHOLDER="utun99"
ONEEXIT_FIREWALL_LABEL="com.oneexit.firewall"
ONEEXIT_TUNNEL_LABEL="com.oneexit.tunnel"
ONEEXIT_DEFAULT_DNS="10.66.0.1"
# Asked in order for the public IPv4 (oneexit status, leak test); the first
# that answers wins, so one blocked or unresolvable service does not matter.
ONEEXIT_IPV4_SERVICES="https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com"

# sudo and launchd give a bare PATH. Put the Homebrew directories in front
# (wg-quick needs Homebrew's bash 4+, not /bin/bash 3.2), but leave a directory
# where it is if PATH already has it, so callers keep their own order.
for _p in /usr/local/sbin /usr/local/bin /opt/homebrew/sbin /opt/homebrew/bin; do
  case ":${PATH}:" in
    *":${_p}:"*) ;;
    *) [ -d "${_p}" ] && PATH="${_p}:${PATH}" ;;
  esac
done
for _p in /usr/bin /bin /usr/sbin /sbin; do
  case ":${PATH}:" in
    *":${_p}:"*) ;;
    *) PATH="${PATH}:${_p}" ;;
  esac
done
unset _p
export PATH

# ---------------------------------------------------------------- logging

if [ -t 1 ]; then
  _C_BOLD=$'\033[1m'
  _C_GREEN=$'\033[32m'
  _C_RESET=$'\033[0m'
else
  _C_BOLD=""
  _C_GREEN=""
  _C_RESET=""
fi
if [ -t 2 ]; then
  _C_YELLOW=$'\033[33m'
  _C_RED=$'\033[31m'
  _C_ERESET=$'\033[0m'
else
  _C_YELLOW=""
  _C_RED=""
  _C_ERESET=""
fi

log_step() { printf '%s==> %s%s\n' "${_C_BOLD}" "$*" "${_C_RESET}"; }
log_ok() { printf '%sok:%s %s\n' "${_C_GREEN}" "${_C_RESET}" "$*"; }
log_info() { printf '%s\n' "$*"; }
log_warn() { printf '%swarn:%s %s\n' "${_C_YELLOW}" "${_C_ERESET}" "$*" >&2; }
log_error() { printf '%serror:%s %s\n' "${_C_RED}" "${_C_ERESET}" "$*" >&2; }
die() {
  log_error "$*"
  exit 1
}
usage_error() {
  log_error "$*"
  exit 2
}

# Timestamped line for daemon logs (stdout is redirected by launchd).
log_ts() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# ---------------------------------------------------------------- dry-run

# Quote one word for display so that a printed command can be pasted back.
shell_quote() {
  case "$1" in
    '') printf "''" ;;
    *[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

quote_cmd() {
  local out="" word
  for word in "$@"; do
    out="${out}${out:+ }$(shell_quote "${word}")"
  done
  printf '%s' "${out}"
}

is_dry_run() { [ "${DRY_RUN}" = "1" ]; }

# run CMD ARGS...: execute, or print "[dry-run] CMD ARGS" when DRY_RUN=1.
run() {
  if is_dry_run; then
    printf '[dry-run] %s\n' "$(quote_cmd "$@")"
    return 0
  fi
  "$@"
}

# write_file PATH MODE < content
# Writes stdin atomically to PATH with MODE. In dry-run, prints the content.
write_file() {
  local path="$1" mode="$2" content dir tmp
  content="$(cat)"
  if is_dry_run; then
    printf '[dry-run] write %s (mode %s):\n' "${path}" "${mode}"
    printf '%s\n' "${content}" | sed 's/^/    | /'
    return 0
  fi
  dir="$(dirname "${path}")"
  mkdir -p "${dir}"
  tmp="$(mktemp "${dir}/.oneexit.XXXXXX")"
  printf '%s\n' "${content}" >"${tmp}"
  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${path}"
}

# write_secret_file PATH MODE < content
# Like write_file, but the temp file is private from the start and dry-run
# output hides PrivateKey / PresharedKey values.
write_secret_file() {
  local path="$1" mode="$2" content dir tmp
  content="$(cat)"
  if is_dry_run; then
    printf '[dry-run] write %s (mode %s, keys hidden):\n' "${path}" "${mode}"
    printf '%s\n' "${content}" |
      sed -E 's/^([[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=).*/\1 (hidden)/I' |
      sed 's/^/    | /'
    return 0
  fi
  dir="$(dirname "${path}")"
  mkdir -p "${dir}"
  tmp="$(umask 077 && mktemp "${dir}/.oneexit.XXXXXX")"
  printf '%s\n' "${content}" >"${tmp}"
  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${path}"
}

is_root() { [ "$(id -u)" -eq 0 ]; }

require_root() {
  if is_dry_run; then
    return 0
  fi
  if ! is_root; then
    die "this command changes system settings; run it with sudo (or add --dry-run to preview)"
  fi
}

now_epoch() { date +%s; }

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_ipv4() {
  local ip="$1" a b c d rest octet
  case "${ip}" in
    *[!0-9.]* | '') return 1 ;;
  esac
  IFS=. read -r a b c d rest <<EOT
${ip}
EOT
  [ -z "${rest}" ] || return 1
  for octet in "${a}" "${b}" "${c}" "${d}"; do
    is_uint "${octet}" || return 1
    [ "${#octet}" -le 3 ] || return 1
    [ "${octet}" -le 255 ] || return 1
  done
  return 0
}

is_port() {
  is_uint "$1" || return 1
  [ "${#1}" -le 5 ] || return 1
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_utun_name() {
  case "$1" in
    utun) return 1 ;;
    utun*) is_uint "${1#utun}" ;;
    *) return 1 ;;
  esac
}

is_iface_name() {
  case "$1" in
    '' | *[!a-z0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------- config

# load_config [FILE]: read the KEY=value config without sourcing it.
# Sets VPS_IP, VPS_PORT, VPS_HOST, WG_IFACE_CONF, PHYS_IFACES, TUNNEL_DNS.
load_config() {
  local file="${1:-${ONEEXIT_CONFIG}}" key value
  VPS_IP=""
  VPS_PORT=""
  VPS_HOST=""
  WG_IFACE_CONF=""
  PHYS_IFACES=""
  TUNNEL_DNS=""
  if [ ! -r "${file}" ]; then
    WG_IFACE_CONF="${ONEEXIT_WG_CONF}"
    TUNNEL_DNS="${ONEEXIT_DEFAULT_DNS}"
    return 1
  fi
  while IFS='=' read -r key value || [ -n "${key}" ]; do
    case "${key}" in
      '' | '#'*) continue ;;
    esac
    value="${value%\"}"
    value="${value#\"}"
    case "${key}" in
      VPS_IP) VPS_IP="${value}" ;;
      VPS_PORT) VPS_PORT="${value}" ;;
      VPS_HOST) VPS_HOST="${value}" ;;
      WG_IFACE_CONF) WG_IFACE_CONF="${value}" ;;
      PHYS_IFACES) PHYS_IFACES="${value}" ;;
      TUNNEL_DNS) TUNNEL_DNS="${value}" ;;
      *) ;;
    esac
  done <"${file}"
  [ -n "${WG_IFACE_CONF}" ] || WG_IFACE_CONF="${ONEEXIT_WG_CONF}"
  [ -n "${TUNNEL_DNS}" ] || TUNNEL_DNS="${ONEEXIT_DEFAULT_DNS}"
  return 0
}

# state_value KEY: read KEY from the setup state file (PF_WAS_ENABLED, ...).
state_value() {
  local want="$1" key value
  [ -r "${ONEEXIT_STATE_FILE}" ] || return 1
  while IFS='=' read -r key value || [ -n "${key}" ]; do
    if [ "${key}" = "${want}" ]; then
      printf '%s\n' "${value}"
      return 0
    fi
  done <"${ONEEXIT_STATE_FILE}"
  return 1
}

# ---------------------------------------------------------------- system probes

# boot_volume_is_external: 0 external, 1 internal, 2 cannot tell.
# External if "Device Location: External" or the protocol is USB/Thunderbolt.
boot_volume_is_external() {
  local info
  command -v diskutil >/dev/null 2>&1 || return 2
  info="$(diskutil info / 2>/dev/null)" || return 2
  [ -n "${info}" ] || return 2
  if printf '%s\n' "${info}" | grep -Eq '^[[:space:]]*Device Location:[[:space:]]*External'; then
    return 0
  fi
  if printf '%s\n' "${info}" | grep -Eq '^[[:space:]]*Protocol:[[:space:]]*(USB|Thunderbolt)'; then
    return 0
  fi
  return 1
}

# boot_volume_summary: the diskutil lines that matter, for messages.
boot_volume_summary() {
  command -v diskutil >/dev/null 2>&1 || {
    printf '    (diskutil not found)\n'
    return 0
  }
  diskutil info / 2>/dev/null |
    grep -E '^[[:space:]]*(Device / Media Name|Protocol|Device Location|Removable Media|Solid State):' |
    sed 's/^[[:space:]]*/    /' || true
}

# network_services: one enabled network service name per line.
network_services() {
  command -v networksetup >/dev/null 2>&1 || return 0
  networksetup -listallnetworkservices 2>/dev/null |
    sed '1d' |
    grep -v '^\*' |
    grep -v '^[[:space:]]*$' || true
}

# phys_ifaces: space-separated list of en* devices (fallback: en0).
phys_ifaces() {
  local list=""
  if command -v networksetup >/dev/null 2>&1; then
    list="$(networksetup -listallhardwareports 2>/dev/null |
      awk '/^Device:[[:space:]]*en[0-9]+[[:space:]]*$/ { if (!seen[$2]++) printf "%s%s", sep, $2; sep = " " }')" || list=""
  fi
  [ -n "${list}" ] || list="en0"
  printf '%s\n' "${list}"
}

# effective_phys_ifaces: PHYS_IFACES from the config, or the live hardware
# ports when it is "auto" (or unset), so a new USB/Thunderbolt adapter works.
effective_phys_ifaces() {
  case "${PHYS_IFACES:-auto}" in
    auto | '') phys_ifaces ;;
    *) printf '%s\n' "${PHYS_IFACES}" ;;
  esac
}

# tunnel_iface [WG_ADDRESS]: the utun device that carries the WireGuard tunnel.
# Like wg-quick's get_real_interface: the name recorded in wg0.name only
# counts if wireguard-go's control socket for that device exists.
tunnel_iface() {
  local addr="${1:-}" name=""
  if [ -r "${ONEEXIT_WG_RUN_DIR}/wg0.name" ]; then
    name="$(head -n 1 "${ONEEXIT_WG_RUN_DIR}/wg0.name" 2>/dev/null | tr -d '[:space:]')" || name=""
    if [ -z "${name}" ] || [ ! -e "${ONEEXIT_WG_RUN_DIR}/${name}.sock" ]; then
      name=""
    fi
  fi
  if [ -z "${name}" ] && command -v wg >/dev/null 2>&1; then
    name="$(wg show interfaces 2>/dev/null | awk '{ print $1 }')" || name=""
  fi
  if [ -z "${name}" ] && [ -n "${addr}" ] && command -v ifconfig >/dev/null 2>&1; then
    addr="${addr%%/*}"
    name="$(ifconfig 2>/dev/null | awk -v want="${addr}" '
      /^[a-z]/ { iface = $1; sub(":$", "", iface) }
      $1 == "inet" && $2 == want && iface ~ /^utun/ { print iface; exit }')" || name=""
  fi
  [ -n "${name}" ] || return 1
  printf '%s\n' "${name}"
}

# wg_dev: the real utunN device to pass to "wg show" (wireguard-go's socket
# is named after it; "wg show wg0" does not work on macOS). Empty and 1 if
# the tunnel is down.
wg_dev() {
  local name
  name="$(tunnel_iface 2>/dev/null || true)"
  if is_utun_name "${name}"; then
    printf '%s\n' "${name}"
    return 0
  fi
  return 1
}

# wg_tunnel_up: 0 if wireguard-go answers on the tunnel's utun device.
wg_tunnel_up() {
  local dev
  command -v wg >/dev/null 2>&1 || return 1
  dev="$(wg_dev)" || return 1
  wg show "${dev}" >/dev/null 2>&1
}

# tunnel_iface_or_placeholder: the live utun device, or utun99 (matches
# nothing) while the tunnel is down, so pf only lets DHCP and the endpoint out.
tunnel_iface_or_placeholder() {
  wg_dev || printf '%s\n' "${ONEEXIT_TUN_PLACEHOLDER}"
}

# route_default_iface: "interface:" of route -n get default.
route_default_iface() {
  command -v route >/dev/null 2>&1 || return 1
  route -n get default 2>/dev/null | awk '$1 == "interface:" { print $2; found = 1; exit } END { exit !found }'
}

# route_default_gateway: "gateway:" of route -n get default (the router on
# the physical network; on-link, so not covered by the tunnel's 0/1 routes).
route_default_gateway() {
  command -v route >/dev/null 2>&1 || return 1
  route -n get default 2>/dev/null | awk '$1 == "gateway:" { print $2; found = 1; exit } END { exit !found }'
}

# default_route_iface: interface of the IPv4 default route (ignoring utun).
default_route_iface() {
  command -v netstat >/dev/null 2>&1 || return 1
  netstat -rn -f inet 2>/dev/null |
    awk '$1 == "default" && $4 !~ /^utun/ { print $4; exit }'
}

# set_dns_all SERVER...|empty: point every enabled network service at SERVER(s).
# "empty" hands DNS back to DHCP.
set_dns_all() {
  local service found=0
  while IFS= read -r service; do
    [ -n "${service}" ] || continue
    found=1
    run networksetup -setdnsservers "${service}" "$@" ||
      log_warn "could not set DNS on \"${service}\""
  done <<EOT
$(network_services)
EOT
  if [ "${found}" -eq 0 ]; then
    log_warn "no network services found (networksetup missing?)"
  fi
  return 0
}
