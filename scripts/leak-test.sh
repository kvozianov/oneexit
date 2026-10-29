#!/usr/bin/env bash
# oneexit leak test: checks that traffic can only leave through the tunnel.
# Read-only: it never changes pf, routes, DNS or interfaces.
set -euo pipefail

_self="${BASH_SOURCE[0]}"
while [ -h "${_self}" ]; do
  _dir="$(cd -P "$(dirname "${_self}")" && pwd)"
  _self="$(readlink "${_self}")"
  case "${_self}" in /*) ;; *) _self="${_dir}/${_self}" ;; esac
done
SELF_DIR="$(cd -P "$(dirname "${_self}")" && pwd)"
LIB_DIR=""
for _cand in "${ONEEXIT_LIB_DIR:-}" "${SELF_DIR}/lib" "${SELF_DIR}/../client/lib" /usr/local/libexec/oneexit/lib; do
  if [ -n "${_cand}" ] && [ -f "${_cand}/common.sh" ]; then
    LIB_DIR="${_cand}"
    break
  fi
done
if [ -z "${LIB_DIR}" ]; then
  echo "error: cannot find the oneexit libraries (common.sh)" >&2
  exit 1
fi
# shellcheck source=../client/lib/common.sh
. "${LIB_DIR}/common.sh"
# shellcheck source=../client/lib/pf.sh
. "${LIB_DIR}/pf.sh"

MAX_HANDSHAKE_AGE=180
IPV4_SERVICES="https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com"
WEBRTC_URL="https://browserleaks.com/webrtc"

usage() {
  cat <<USAGE
Usage: sudo scripts/leak-test.sh [--expect-ip IP] [--iface IFACE] [--json] [--dry-run] [--help]

Checks, each reported as PASS, FAIL, SKIP or INFO:
  1. pf          pf enabled, main ruleset has the "com.apple/*" hook and anchor
                 ${ONEEXIT_ANCHOR} has rules (needs root)
  2. handshake   WireGuard handshake younger than ${MAX_HANDSHAKE_AGE} s (needs root)
  3. ipv4        public IPv4 equals VPS_IP from the config (or --expect-ip)
  4. ipv6        IPv6 connectivity must fail
  5. dns         the system resolver's public IP (whoami.akamai.net) equals VPS_IP
  6. direct      a request bound to the physical interface must fail
  7. bonjour     the anchor contains "block all" (mDNS stays local; needs root)
  8. webrtc      what to check by hand in a browser

Options:
  --expect-ip IP   expected public IPv4 (default: VPS_IP from ${ONEEXIT_CONFIG})
  --iface IFACE    physical interface for the direct check (default: the interface of
                   the default route from "route -n get default")
  --json           print the results as a JSON array
  --dry-run        print the commands that would run; run nothing
  --help           show this help

Exit codes: 0 no FAIL, 1 at least one FAIL, 2 usage error.
Without root the pf checks are skipped; the network checks still run.
USAGE
}

JSON=0
EXPECT_IP=""
IFACE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --expect-ip)
      [ "$#" -ge 2 ] || usage_error "--expect-ip needs an address"
      is_ipv4 "$2" || usage_error "--expect-ip must be an IPv4 address"
      EXPECT_IP="$2"
      shift
      ;;
    --iface)
      [ "$#" -ge 2 ] || usage_error "--iface needs an interface name"
      is_iface_name "$2" || usage_error "invalid interface name: $2"
      IFACE="$2"
      shift
      ;;
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

load_config || true

# ---------------------------------------------------------------- results

R_NAME=()
R_STATUS=()
R_REASON=()
FAILS=0

record() {
  local status="$1" name="$2" reason="$3"
  R_STATUS+=("${status}")
  R_NAME+=("${name}")
  R_REASON+=("${reason}")
  [ "${status}" != "FAIL" ] || FAILS=$((FAILS + 1))
  if [ "${JSON}" -eq 0 ]; then
    printf '%-4s  %-10s %s\n' "${status}" "${name}" "${reason}"
  fi
}

# show_cmd CMD...: in dry-run, print the command (stderr when --json).
show_cmd() {
  if [ "${JSON}" -eq 1 ]; then
    printf '[dry-run] %s\n' "$(quote_cmd "$@")" >&2
  else
    printf '[dry-run] %s\n' "$(quote_cmd "$@")"
  fi
}

json_escape() {
  printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

print_json() {
  local i=0 n="${#R_NAME[@]}" sep=""
  printf '['
  while [ "${i}" -lt "${n}" ]; do
    printf '%s\n  {"check": "%s", "status": "%s", "reason": "%s"}' "${sep}" \
      "$(json_escape "${R_NAME[${i}]}")" \
      "$(json_escape "${R_STATUS[${i}]}")" \
      "$(json_escape "${R_REASON[${i}]}")"
    sep=","
    i=$((i + 1))
  done
  printf '\n]\n'
}

first_ipv4() { grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1; }

# ---------------------------------------------------------------- checks

check_pf() {
  local info rules hook_rc=0
  if is_dry_run; then
    show_cmd pfctl -s info
    show_cmd pfctl -s rules
    show_cmd pfctl -a "${ONEEXIT_ANCHOR}" -s rules
    record SKIP pf "dry-run"
    return 0
  fi
  if ! command -v pfctl >/dev/null 2>&1; then
    record SKIP pf "pfctl not found"
    return 0
  fi
  if ! is_root; then
    record SKIP pf "needs root (run with sudo)"
    return 0
  fi
  if ! info="$(pfctl -s info 2>&1)"; then
    case "${info}" in
      *ermission*) record SKIP pf "needs root (permission denied)" ;;
      *) record FAIL pf "pfctl -s info failed" ;;
    esac
    return 0
  fi
  if ! printf '%s\n' "${info}" | grep -q '^Status: Enabled'; then
    record FAIL pf "pf is disabled"
    return 0
  fi
  pf_main_has_hook || hook_rc=$?
  if [ "${hook_rc}" -eq 1 ]; then
    record FAIL pf "${PF_HOOK_MISSING_MSG}"
    return 0
  elif [ "${hook_rc}" -ne 0 ]; then
    record SKIP pf "cannot read the main ruleset (pfctl -s rules)"
    return 0
  fi
  rules="$(pfctl -a "${ONEEXIT_ANCHOR}" -s rules 2>/dev/null || true)"
  if [ -z "${rules}" ]; then
    record FAIL pf "pf enabled but anchor ${ONEEXIT_ANCHOR} is empty"
  else
    record PASS pf "pf enabled, com.apple/* hook present, anchor ${ONEEXIT_ANCHOR} has $(printf '%s\n' "${rules}" | grep -c .) rules"
  fi
}

check_handshake() {
  local out hs age dev
  if is_dry_run; then
    show_cmd wg show "$(wg_dev || echo "<utun device>")" latest-handshakes
    record SKIP handshake "dry-run"
    return 0
  fi
  if ! command -v wg >/dev/null 2>&1; then
    record SKIP handshake "wg not installed"
    return 0
  fi
  if ! is_root; then
    record SKIP handshake "needs root (run with sudo)"
    return 0
  fi
  if ! dev="$(wg_dev)"; then
    record FAIL handshake "tunnel wg0 is not up (no utun device)"
    return 0
  fi
  if ! out="$(wg show "${dev}" latest-handshakes 2>&1)"; then
    record FAIL handshake "wg show ${dev} failed: ${out}"
    return 0
  fi
  hs="$(printf '%s\n' "${out}" | awk 'BEGIN { m = 0 } $2 + 0 > m { m = $2 + 0 } END { print m }')"
  if [ "${hs}" -eq 0 ]; then
    record FAIL handshake "no handshake with the server yet"
    return 0
  fi
  age=$(($(now_epoch) - hs))
  if [ "${age}" -le "${MAX_HANDSHAKE_AGE}" ]; then
    record PASS handshake "last handshake on ${dev} ${age} s ago"
  else
    record FAIL handshake "last handshake ${age} s ago (> ${MAX_HANDSHAKE_AGE} s)"
  fi
}

check_ipv4() {
  local url ip="" expected="${EXPECT_IP:-${VPS_IP:-}}"
  if is_dry_run; then
    for url in ${IPV4_SERVICES}; do
      show_cmd curl -4 -s -m 10 "${url}"
    done
    record SKIP ipv4 "dry-run"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    record SKIP ipv4 "curl not found"
    return 0
  fi
  for url in ${IPV4_SERVICES}; do
    ip="$(curl -4 -s -m 10 "${url}" 2>/dev/null | tr -d '[:space:]' | first_ipv4 || true)"
    [ -z "${ip}" ] || break
  done
  if [ -z "${expected}" ]; then
    record INFO ipv4 "public IPv4 is ${ip:-unknown (no answer)}; pass --expect-ip to compare"
  elif [ -z "${ip}" ]; then
    record FAIL ipv4 "no answer from ${IPV4_SERVICES// /, } (tunnel down?)"
  elif [ "${ip}" = "${expected}" ]; then
    record PASS ipv4 "public IPv4 ${ip} is the expected exit"
  else
    record FAIL ipv4 "public IPv4 ${ip} is not ${expected}: traffic leaves outside the tunnel"
  fi
}

check_ipv6() {
  local out
  if is_dry_run; then
    show_cmd curl -6 -s -m 5 https://api64.ipify.org
    record SKIP ipv6 "dry-run"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    record SKIP ipv6 "curl not found"
    return 0
  fi
  if out="$(curl -6 -s -m 5 https://api64.ipify.org 2>/dev/null)"; then
    record FAIL ipv6 "IPv6 is reachable (public address ${out:-unknown})"
  else
    record PASS ipv6 "no IPv6 connectivity"
  fi
}

check_dns() {
  local ip expected="${VPS_IP:-${EXPECT_IP:-}}"
  if is_dry_run; then
    show_cmd dig +short +time=3 +tries=2 whoami.akamai.net
    record SKIP dns "dry-run"
    return 0
  fi
  if ! command -v dig >/dev/null 2>&1; then
    record SKIP dns "dig not found"
    return 0
  fi
  ip="$(dig +short +time=3 +tries=2 whoami.akamai.net 2>/dev/null | first_ipv4 || true)"
  if [ -z "${ip}" ]; then
    record FAIL dns "no answer for whoami.akamai.net through the system resolver"
  elif [ -z "${expected}" ]; then
    record INFO dns "system resolver reaches the internet as ${ip}; pass --expect-ip to compare"
  elif [ "${ip}" = "${expected}" ]; then
    record PASS dns "DNS is resolved by your server (${ip})"
  else
    record FAIL dns "DNS is resolved from ${ip}, not ${expected}: DNS leaks outside the tunnel"
  fi
}

# direct_iface: --iface, else the interface of the default route
# (route -n get default), else the first physical interface, else en0.
direct_iface() {
  local dev
  if [ -n "${IFACE}" ]; then
    printf '%s\n' "${IFACE}"
    return 0
  fi
  dev="$(route_default_iface || true)"
  case "${dev}" in
    '' | utun* | lo*) dev="$(default_route_iface || true)" ;;
    *) ;;
  esac
  case "${dev}" in
    '' | utun* | lo*)
      dev="$(effective_phys_ifaces)"
      dev="${dev%% *}"
      ;;
    *) ;;
  esac
  printf '%s\n' "${dev:-en0}"
}

check_direct() {
  if is_dry_run; then
    show_cmd route -n get default
    show_cmd curl --interface "<default-route interface>" -s -m 5 -o /dev/null http://1.1.1.1
    record SKIP direct "dry-run"
    return 0
  fi
  IFACE="$(direct_iface)"
  if ! command -v curl >/dev/null 2>&1; then
    record SKIP direct "curl not found"
    return 0
  fi
  if command -v ifconfig >/dev/null 2>&1 && ! ifconfig "${IFACE}" >/dev/null 2>&1; then
    record SKIP direct "interface ${IFACE} does not exist"
    return 0
  fi
  if curl --interface "${IFACE}" -s -m 5 -o /dev/null http://1.1.1.1 2>/dev/null; then
    record FAIL direct "a request bound to ${IFACE} reached 1.1.1.1 outside the tunnel"
  else
    record PASS direct "requests bound to ${IFACE} are blocked"
  fi
}

check_bonjour() {
  local rules
  if is_dry_run; then
    show_cmd pfctl -a "${ONEEXIT_ANCHOR}" -s rules
    record SKIP bonjour "dry-run"
    return 0
  fi
  if ! command -v pfctl >/dev/null 2>&1; then
    record SKIP bonjour "pfctl not found"
    return 0
  fi
  if ! is_root; then
    record SKIP bonjour "needs root (run with sudo)"
    return 0
  fi
  rules="$(pfctl -a "${ONEEXIT_ANCHOR}" -s rules 2>/dev/null || true)"
  if printf '%s\n' "${rules}" | grep -Eq '^block( drop| return)? all'; then
    record PASS bonjour "anchor blocks all other traffic, mDNS/Bonjour included"
  else
    record FAIL bonjour "anchor ${ONEEXIT_ANCHOR} has no \"block all\" rule"
  fi
}

check_webrtc() {
  record INFO webrtc "open ${WEBRTC_URL} in each browser: only ${VPS_IP:-your VPS IP} may appear; no LAN, ISP or IPv6 addresses"
}

check_pf
check_handshake
check_ipv4
check_ipv6
check_dns
check_direct
check_bonjour
check_webrtc

if [ "${JSON}" -eq 1 ]; then
  print_json
else
  printf '\n%s FAIL(s)\n' "${FAILS}"
fi

if [ "${FAILS}" -gt 0 ]; then
  exit 1
fi
exit 0
