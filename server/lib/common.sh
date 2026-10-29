#!/usr/bin/env bash
# Shared helpers for the oneexit server scripts: logging, dry-run handling,
# root and OS checks, network detection.
#
# Environment:
#   DRY_RUN=1       print commands and file contents instead of executing them
#   ONEEXIT_ROOT    path prefix for every file the scripts read or write
#                   (testing only; empty in normal use)

DRY_RUN="${DRY_RUN:-0}"
ONEEXIT_ROOT="${ONEEXIT_ROOT:-}"

# Placeholder endpoint used when nothing better is known in dry-run
# (RFC 5737 documentation address).
DRYRUN_ENDPOINT="203.0.113.5"

if [[ -t 2 ]]; then
  _C_BOLD=$'\033[1m'
  _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'
  _C_RED=$'\033[31m'
  _C_RESET=$'\033[0m'
else
  _C_BOLD=""
  _C_GREEN=""
  _C_YELLOW=""
  _C_RED=""
  _C_RESET=""
fi

# Logging goes to stderr so stdout stays clean (peer.sh prints configs there).
step() { printf '%s==> %s%s\n' "${_C_BOLD}" "$*" "${_C_RESET}" >&2; }
ok() { printf '%sok:%s %s\n' "${_C_GREEN}" "${_C_RESET}" "$*" >&2; }
warn() { printf '%swarn:%s %s\n' "${_C_YELLOW}" "${_C_RESET}" "$*" >&2; }
error() { printf '%serror:%s %s\n' "${_C_RED}" "${_C_RESET}" "$*" >&2; }
die() {
  error "$*"
  exit 1
}

is_dry_run() { [[ "${DRY_RUN}" == "1" ]]; }

# Prefix a system path with ONEEXIT_ROOT.
root_path() { printf '%s%s\n' "${ONEEXIT_ROOT}" "$1"; }

# run CMD [ARGS...]: execute, or print "[dry-run] CMD ARGS" in dry-run mode.
run() {
  if is_dry_run; then
    local out="" arg
    for arg in "$@"; do
      out+="$(printf '%q' "${arg}") "
    done
    printf '[dry-run] %s\n' "${out% }"
  else
    "$@"
  fi
}

# write_file PATH MODE: read content from stdin and write it atomically
# (temp file in the same directory + rename). In dry-run, print the content.
write_file() {
  local path="$1" mode="$2" dir tmp
  if is_dry_run; then
    printf '[dry-run] write %s (mode %s):\n' "${path}" "${mode}"
    cat
    return 0
  fi
  dir="$(dirname "${path}")"
  mkdir -p "${dir}"
  tmp="$(mktemp "${dir}/.oneexit.XXXXXX")"
  if ! cat >"${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${path}"
  ok "wrote ${path} (mode ${mode})"
}

require_root() {
  is_dry_run && return 0
  if [[ "$(id -u)" -ne 0 ]]; then
    die "must be run as root (try: sudo $0 ...), or use --dry-run"
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
  done
}

# detect_os: succeed on Debian 12+ and Ubuntu 22.04+, print the name on stdout.
# Reads ${ONEEXIT_ROOT}/etc/os-release. Returns 1 with an error otherwise.
detect_os() {
  local file id="" version="" major line
  file="$(root_path /etc/os-release)"
  if [[ ! -r "${file}" ]]; then
    error "cannot read ${file}: unsupported OS (need Debian 12+ or Ubuntu 22.04+)"
    return 1
  fi
  while IFS= read -r line; do
    case "${line}" in
      ID=*) id="${line#ID=}" ;;
      VERSION_ID=*) version="${line#VERSION_ID=}" ;;
    esac
  done <"${file}"
  id="${id//\"/}"
  version="${version//\"/}"
  major="${version%%.*}"
  if [[ ! "${major}" =~ ^[0-9]+$ ]]; then
    error "unsupported OS: ${id:-unknown} ${version:-?} (need Debian 12+ or Ubuntu 22.04+)"
    return 1
  fi
  case "${id}" in
    debian)
      if ((major >= 12)); then
        printf 'Debian %s\n' "${version}"
        return 0
      fi
      ;;
    ubuntu)
      if ((major >= 22)); then
        printf 'Ubuntu %s\n' "${version}"
        return 0
      fi
      ;;
  esac
  error "unsupported OS: ${id:-unknown} ${version} (need Debian 12+ or Ubuntu 22.04+)"
  return 1
}

# default_iface: name of the interface that carries the default IPv4 route.
# Falls back to "eth0" in dry-run when it cannot be determined (e.g. macOS).
default_iface() {
  local iface=""
  if command -v ip >/dev/null 2>&1; then
    iface="$(ip route show default 2>/dev/null |
      awk '!found { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); found = 1; break } }')"
  fi
  if [[ -n "${iface}" ]]; then
    printf '%s\n' "${iface}"
    return 0
  fi
  if is_dry_run; then
    printf 'eth0\n'
    return 0
  fi
  error "could not determine the default network interface (ip route show default)"
  return 1
}

is_ipv4() {
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# public_ip [FALLBACK]: best-effort public IPv4 of this server. Prints FALLBACK
# if given (no network access in that case is needed). In dry-run, no network
# request is made and the documentation address is used without a fallback.
public_ip() {
  local fallback="${1:-}" url ip
  if [[ -n "${fallback}" ]]; then
    printf '%s\n' "${fallback}"
    return 0
  fi
  if is_dry_run; then
    printf '%s\n' "${DRYRUN_ENDPOINT}"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    for url in https://api.ipify.org https://ifconfig.me/ip; do
      ip="$(curl -4 -fsS -m 10 "${url}" 2>/dev/null | tr -d '[:space:]')" || ip=""
      if is_ipv4 "${ip}"; then
        printf '%s\n' "${ip}"
        return 0
      fi
    done
  fi
  error "could not detect the public IP; pass --endpoint HOST_OR_IP"
  return 1
}

# valid_peer_name NAME: letters, digits, '-' and '_', 1-32 characters.
valid_peer_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (($1 >= 1 && $1 <= 65535))
}

# Hostname or IPv4 address (IPv6 endpoints are not supported in v1).
valid_endpoint() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

# read_state FILE: load ENDPOINT and PORT from a KEY=value file without
# sourcing it. Sets STATE_ENDPOINT and STATE_PORT (empty when absent).
# shellcheck disable=SC2034  # read by the calling script
read_state() {
  local file="$1" key value
  STATE_ENDPOINT=""
  STATE_PORT=""
  [[ -r "${file}" ]] || return 0
  while IFS='=' read -r key value; do
    value="${value//\"/}"
    case "${key}" in
      ENDPOINT) STATE_ENDPOINT="${value}" ;;
      PORT) STATE_PORT="${value}" ;;
    esac
  done <"${file}"
}
