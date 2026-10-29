#!/usr/bin/env bash
# Integration smoke test for the server half. Runs the real installer on a
# disposable Debian/Ubuntu machine (the CI ubuntu runner) and checks the
# result. Changes the system: never run it on a server you care about.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "${SCRIPT_DIR}/../../server" && pwd)"
ENDPOINT="203.0.113.5"
PORT="51820"
LOG_DIR="${ONEEXIT_IT_LOG_DIR:-/tmp/oneexit-integration}"

usage() {
  cat <<'USAGE'
Usage: sudo tests/server/integration.sh

Runs server/install.sh --endpoint 203.0.113.5 --peer ci for real, then checks
wg0, nftables, unbound and peer.sh add/list/revoke. Linux, root, disposable
machine only (CI). Exit 0 if every check passes, 1 on the first failure.
USAGE
}

pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

diagnostics() {
  printf '\n--- diagnostics ---\n' >&2
  systemctl --no-pager status wg-quick@wg0 unbound >&2 || true
  journalctl --no-pager -n 40 -u wg-quick@wg0 -u unbound >&2 || true
  nft list ruleset >&2 || true
  ss -lunp >&2 || true
}

# check DESCRIPTION CMD [ARGS...]
check() {
  local desc="$1"
  shift
  if "$@"; then
    pass "${desc}"
  else
    diagnostics
    fail "${desc}"
  fi
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  "") ;;
  *)
    usage >&2
    exit 2
    ;;
esac

[[ "$(uname -s)" == "Linux" ]] || fail "this test needs Linux (Debian/Ubuntu)"
[[ "$(id -u)" -eq 0 ]] || fail "this test must run as root"
mkdir -p "${LOG_DIR}"

# WireGuard needs kernel support; wg-quick cannot work without it. Probe with
# `ip link add ... type wireguard` (the same call wg-quick makes).
modprobe wireguard 2>/dev/null || true
if ip link add oneexit-probe type wireguard 2>/dev/null; then
  ip link del oneexit-probe
  pass "kernel supports WireGuard interfaces"
else
  fail "this kernel cannot create WireGuard interfaces (modprobe wireguard and 'ip link add type wireguard' failed); the integration test cannot run here"
fi

# --- install -----------------------------------------------------------------
if ! "${SERVER_DIR}/install.sh" --endpoint "${ENDPOINT}" --peer ci >"${LOG_DIR}/install.log" 2>&1; then
  cat "${LOG_DIR}/install.log" >&2
  diagnostics
  fail "install.sh exited non-zero (log above)"
fi
pass "install.sh --endpoint ${ENDPOINT} --peer ci"

grep -q '^\[Interface\]$' "${LOG_DIR}/install.log" || fail "install.sh did not print the peer config"
pass "install.sh printed the peer config"

check "wg show wg0" wg show wg0
check "wg0 listens on ${PORT}" test "$(wg show wg0 listen-port)" = "${PORT}"
has_tunnel_address() {
  local addrs
  addrs="$(ip -4 addr show dev wg0)"
  grep -q 'inet 10\.66\.0\.1/24' <<<"${addrs}"
}
check "wg0 has address 10.66.0.1/24" has_tunnel_address
check "net.ipv4.ip_forward = 1" test "$(sysctl -n net.ipv4.ip_forward)" = "1"

ruleset="$(nft list ruleset)"
check "nft ruleset contains masquerade" grep -q 'masquerade' <<<"${ruleset}"
check "nft ruleset contains udp dport ${PORT}" grep -q "udp dport ${PORT}" <<<"${ruleset}"
check "nftables.conf includes the oneexit ruleset" grep -qF 'include "/etc/nftables.d/oneexit.nft"' /etc/nftables.conf

# Local addresses of listening UDP sockets. Callers read the whole output
# (no `grep -q`), so an early exit cannot break the pipe under pipefail.
udp_listeners() {
  local sockets
  sockets="$(ss -lunH)"
  awk '{ print $4 }' <<<"${sockets}"
}

dns_listening() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if udp_listeners | grep -x '10\.66\.0\.1:53' >/dev/null; then
      return 0
    fi
    sleep 1
    : "${i}"
  done
  return 1
}
check "unbound listens on 10.66.0.1:53 (udp)" dns_listening
no_wildcard_dns() {
  ! udp_listeners | grep -x '0\.0\.0\.0:53' >/dev/null
}
check "nothing listens on 0.0.0.0:53" no_wildcard_dns

for unit in wg-quick@wg0 unbound nftables; do
  check "${unit} is enabled" systemctl is-enabled --quiet "${unit}"
done

if command -v dig >/dev/null 2>&1; then
  if [[ -n "$(dig +short +time=5 +tries=2 -b 10.66.0.1 @10.66.0.1 example.com A 2>/dev/null)" ]]; then
    pass "unbound resolves example.com for the tunnel subnet"
  else
    printf 'WARN: unbound did not resolve example.com (network on the runner?)\n' >&2
  fi
fi

check "first peer config saved with mode 600" test "$(stat -c '%a' /etc/wireguard/peers/ci.conf)" = "600"
check "wg0.conf has mode 600" test "$(stat -c '%a' /etc/wireguard/wg0.conf)" = "600"

# --- peer.sh -----------------------------------------------------------------
out="$("${SERVER_DIR}/peer.sh" add laptop 2>"${LOG_DIR}/peer-add.err")" ||
  fail "peer.sh add laptop exited non-zero: $(cat "${LOG_DIR}/peer-add.err")"
check "peer.sh add laptop prints [Interface]" grep -qx '\[Interface\]' <<<"${out}"
check "peer.sh add laptop prints Endpoint = ${ENDPOINT}:${PORT}" grep -qx "Endpoint = ${ENDPOINT}:${PORT}" <<<"${out}"
check "peer.sh add laptop allocates 10.66.0.3" grep -qx 'Address = 10.66.0.3/32' <<<"${out}"
check "wg0 has two live peers" test "$(wg show wg0 peers | wc -l)" -eq 2

list="$("${SERVER_DIR}/peer.sh" list 2>/dev/null)"
check "peer.sh list shows ci" grep -q '^ci ' <<<"${list}"
check "peer.sh list shows laptop" grep -q '^laptop ' <<<"${list}"
check "peer.sh list shows two peers" test "$(tail -n +2 <<<"${list}" | grep -c .)" -eq 2

"${SERVER_DIR}/peer.sh" revoke laptop >/dev/null 2>&1 || fail "peer.sh revoke laptop exited non-zero"
list="$("${SERVER_DIR}/peer.sh" list 2>/dev/null)"
not_listed() { ! grep -q "^$1 " <<<"${list}"; }
check "peer.sh revoke laptop removes it from the list" not_listed laptop
check "peer.sh revoke laptop removes the live peer" test "$(wg show wg0 peers | wc -l)" -eq 1
check "peer.sh revoke laptop deletes its config" test ! -e /etc/wireguard/peers/laptop.conf

# --- idempotency ---------------------------------------------------------------
key_before="$(sha256sum /etc/wireguard/server.key)"
peer_before="$(sha256sum /etc/wireguard/peers/ci.conf)"
if ! "${SERVER_DIR}/install.sh" --endpoint "${ENDPOINT}" --peer ci >"${LOG_DIR}/install2.log" 2>&1; then
  cat "${LOG_DIR}/install2.log" >&2
  fail "second install.sh run exited non-zero"
fi
check "re-running install.sh keeps the server key" test "$(sha256sum /etc/wireguard/server.key)" = "${key_before}"
check "re-running install.sh keeps the first peer" test "$(sha256sum /etc/wireguard/peers/ci.conf)" = "${peer_before}"
check "re-running install.sh adds no peers" test "$(wg show wg0 peers | wc -l)" -eq 1
check "include line appears once in nftables.conf" test "$(grep -cF 'include "/etc/nftables.d/oneexit.nft"' /etc/nftables.conf)" -eq 1

printf '\nAll server integration checks passed.\n'
