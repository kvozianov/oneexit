#!/usr/bin/env bats
# server/install.sh in dry-run (no root, no wg, works on macOS).

load ../helpers/server_helpers

setup() {
  server_setup
  INSTALL_SH="${SERVER_DIR}/install.sh"
}

@test "install.sh --help exits 0; unknown option exits 2" {
  run "${INSTALL_SH}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage: install.sh"* ]]
  run "${INSTALL_SH}" --bogus
  [ "${status}" -eq 2 ]
  run "${INSTALL_SH}" --port 70000 --dry-run
  [ "${status}" -eq 2 ]
}

@test "install.sh --dry-run lists every file it would write and changes nothing" {
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [ "${status}" -eq 0 ]
  for f in /etc/wireguard/server.key /etc/wireguard/server.pub /etc/wireguard/wg0.conf \
    /etc/wireguard/oneexit.env /etc/sysctl.d/99-oneexit.conf /etc/nftables.d/oneexit.nft \
    /etc/nftables.conf /etc/unbound/unbound.conf.d/oneexit.conf /etc/wireguard/peers/mac.conf; do
    [[ "${output}" == *"[dry-run] write ${ONEEXIT_ROOT}${f} "* ]]
  done
  [ -z "$(find "${ONEEXIT_ROOT}" -type f)" ]
}

@test "install.sh --dry-run --port 443 prints packages, services, port, peer config and QR" {
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5 --peer ci --port 443
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"apt-get install -y -q wireguard wireguard-tools unbound nftables qrencode"* ]]
  [[ "${output}" == *"[dry-run] systemctl enable --now wg-quick@wg0"* ]]
  [[ "${output}" == *"[dry-run] systemctl enable unbound"* ]]
  [[ "${output}" == *"[dry-run] systemctl enable nftables"* ]]
  [[ "${output}" == *"[dry-run] nft -f ${ONEEXIT_ROOT}/etc/nftables.d/oneexit.nft"* ]]
  [[ "${output}" == *"Endpoint = 203.0.113.5:443"* ]]
  [[ "${output}" == *"ListenPort = 443"* ]]
  [[ "${output}" == *"udp dport 443 accept"* ]]
  [[ "${output}" == *"masquerade"* ]]
  [[ "${output}" == *"PORT=443"* ]]
  [[ "${output}" == *"[dry-run] qrencode -t ansiutf8 -r ${ONEEXIT_ROOT}/etc/wireguard/peers/ci.conf"* ]]
  [[ "${output}" == *"dry-run: nothing was changed."* ]]
}

@test "install.sh --dry-run keeps an existing wg0.conf, port and peers" {
  install_wg_fixture wg0-two-peers.conf
  printf 'SERVER_PRIV_FIXTURE\n' >"${ONEEXIT_ROOT}/etc/wireguard/server.key"
  printf 'existing\n' >"${ONEEXIT_ROOT}/etc/wireguard/peers/mac.conf"
  run "${INSTALL_SH}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"keeping the existing ${ONEEXIT_ROOT}/etc/wireguard/wg0.conf"* ]]
  [[ "${output}" != *"[dry-run] write ${ONEEXIT_ROOT}/etc/wireguard/wg0.conf"* ]]
  [[ "${output}" != *"[dry-run] write ${ONEEXIT_ROOT}/etc/wireguard/server.key"* ]]
  [[ "${output}" == *"peer mac already exists"* ]]
  [[ "${output}" == *"udp dport 443 accept"* ]]
  [[ "${output}" == *"ENDPOINT=vpn.example.org"* ]]
  # An explicit, different --port conflicts with the existing wg0.conf.
  run "${INSTALL_SH}" --dry-run --port 51820
  [ "${status}" -eq 1 ]
}

@test "install.sh --dry-run appends the include to an existing nftables.conf once" {
  mkdir -p "${ONEEXIT_ROOT}/etc"
  printf '#!/usr/sbin/nft -f\nflush ruleset\n' >"${ONEEXIT_ROOT}/etc/nftables.conf"
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [[ "${output}" == *"$(printf 'flush ruleset\n\n# oneexit (server/install.sh): WireGuard firewall and NAT\ninclude "/etc/nftables.d/oneexit.nft"')"* ]]
  printf 'include "/etc/nftables.d/oneexit.nft"\n' >>"${ONEEXIT_ROOT}/etc/nftables.conf"
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [[ "${output}" != *"[dry-run] write ${ONEEXIT_ROOT}/etc/nftables.conf"* ]]
}
