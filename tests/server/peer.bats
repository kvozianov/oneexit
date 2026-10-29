#!/usr/bin/env bats
# server/peer.sh in dry-run (no root, no wg needed).

load ../helpers/server_helpers

bats_require_minimum_version 1.5.0

setup() {
  server_setup
  PEER_SH="${SERVER_DIR}/peer.sh"
}

@test "peer.sh --help exits 0; bad usage exits 2" {
  run "${PEER_SH}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Usage: peer.sh"* ]]
  run "${PEER_SH}"
  [ "${status}" -eq 2 ]
  run "${PEER_SH}" frobnicate
  [ "${status}" -eq 2 ]
  run "${PEER_SH}" add '../evil' --dry-run
  [ "${status}" -eq 2 ]
}

@test "peer.sh add --dry-run prints a valid client config for 10.66.0.2 on a fresh server" {
  run --separate-stderr "${PEER_SH}" add laptop --dry-run
  [ "${status}" -eq 0 ]
  expected="$(cat <<'CONF'
[Interface]
PrivateKey = DRYRUN_PRIVATE_KEY_1
Address = 10.66.0.2/32
DNS = 10.66.0.1

[Peer]
PublicKey = DRYRUN_SERVER_PUBLIC_KEY
Endpoint = 203.0.113.5:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
)"
  [ "$(last_lines "${output}" 10)" = "${expected}" ]
  [[ "${output}" == *"[dry-run] wg set wg0 peer DRYRUN_PUBLIC_KEY_1 allowed-ips 10.66.0.2/32"* ]]
  [[ "${output}" == *"[dry-run] write ${ONEEXIT_ROOT}/etc/wireguard/peers/laptop.conf (mode 0600):"* ]]
  [ -z "$(find "${ONEEXIT_ROOT}" -type f)" ]
}

@test "peer.sh add --dry-run allocates the next free address and uses the state file" {
  install_wg_fixture wg0-two-peers.conf
  run --separate-stderr "${PEER_SH}" --dry-run add laptop
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Address = 10.66.0.3/32"* ]]
  [[ "${output}" == *"Endpoint = vpn.example.org:443"* ]]
  [[ "${output}" == *"PublicKey = SERVER_PUB_FIXTURE"* ]]
  # The new wg0.conf keeps the existing peers and appends the new one.
  [[ "${output}" == *"# name: phone"* ]]
  [[ "${output}" == *"$(printf '# name: laptop\nPublicKey = DRYRUN_PUBLIC_KEY_1\nAllowedIPs = 10.66.0.3/32')"* ]]
  # --endpoint and --port override the state file.
  run --separate-stderr "${PEER_SH}" add laptop --dry-run --endpoint 198.51.100.7 --port 51821
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Endpoint = 198.51.100.7:51821"* ]]
}

@test "peer.sh add refuses an existing peer name" {
  install_wg_fixture wg0-two-peers.conf
  run "${PEER_SH}" add phone --dry-run
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"already exists"* ]]
}

@test "peer.sh revoke --dry-run removes the section and the live peer" {
  install_wg_fixture wg0-two-peers.conf
  run "${PEER_SH}" revoke mac --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] wg set wg0 peer PUB_MAC remove"* ]]
  [[ "${output}" != *"# name: mac"* ]]
  [[ "${output}" == *"# name: phone"* ]]
  run "${PEER_SH}" revoke nobody --dry-run
  [ "${status}" -eq 1 ]
}

@test "peer.sh list and qr" {
  install_wg_fixture wg0-two-peers.conf
  run --separate-stderr "${PEER_SH}" list
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | grep -c '^mac  *10\.66\.0\.2  *PUB_MAC$')" -eq 1 ]
  [ "$(printf '%s\n' "${output}" | grep -c '^phone  *10\.66\.0\.4  *PUB_PHONE$')" -eq 1 ]
  run "${PEER_SH}" qr mac --dry-run
  [ "${status}" -eq 0 ]
  [ "${output}" = "[dry-run] qrencode -t ansiutf8 -r ${ONEEXIT_ROOT}/etc/wireguard/peers/mac.conf" ]
}
