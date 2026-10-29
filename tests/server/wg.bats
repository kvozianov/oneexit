#!/usr/bin/env bats
# shellcheck disable=SC2034  # DRY_RUN is read by the sourced server libraries
# Pure WireGuard helpers in server/lib/wg.sh.

load ../helpers/server_helpers

setup() {
  server_setup
  load_server_libs
}

@test "render_server_conf prints the exact server config" {
  run render_server_conf 51820 SERVER_PRIV
  [ "${status}" -eq 0 ]
  expected="$(cat <<'CONF'
[Interface]
Address = 10.66.0.1/24
ListenPort = 51820
PrivateKey = SERVER_PRIV
SaveConfig = false

# peers below are managed by peer.sh
CONF
)"
  [ "${output}" = "${expected}" ]
}

@test "render_peer_section prints a named [Peer] block" {
  run render_peer_section laptop PEER_PUB 10.66.0.7
  [ "${status}" -eq 0 ]
  expected="$(cat <<'CONF'
[Peer]
# name: laptop
PublicKey = PEER_PUB
AllowedIPs = 10.66.0.7/32
CONF
)"
  [ "${output}" = "${expected}" ]
}

@test "render_peer_conf prints exactly the contract client config" {
  run render_peer_conf PEER_PRIV 10.66.0.2 SERVER_PUB 203.0.113.5 51820
  [ "${status}" -eq 0 ]
  expected="$(cat <<'CONF'
[Interface]
PrivateKey = PEER_PRIV
Address = 10.66.0.2/32
DNS = 10.66.0.1

[Peer]
PublicKey = SERVER_PUB
Endpoint = 203.0.113.5:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
)"
  [ "${output}" = "${expected}" ]
}

@test "next_peer_ip returns the lowest free address (.2 and .4 taken -> .3)" {
  run next_peer_ip "${SERVER_FIXTURES}/wg0-two-peers.conf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "10.66.0.3" ]
}

@test "next_peer_ip starts at .2 without wg0.conf and fails when .2-.254 are taken" {
  run next_peer_ip "${BATS_TEST_TMPDIR}/missing.conf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "10.66.0.2" ]
  conf="${BATS_TEST_TMPDIR}/full.conf"
  for n in $(seq 2 254); do
    printf '[Peer]\nPublicKey = K%s\nAllowedIPs = 10.66.0.%s/32\n\n' "${n}" "${n}"
  done >"${conf}"
  run next_peer_ip "${conf}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no free address"* ]]
}

@test "remove_peer_section drops only the named peer" {
  run remove_peer_section mac <"${SERVER_FIXTURES}/wg0-two-peers.conf"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"# name: mac"* ]]
  [[ "${output}" != *"PUB_MAC"* ]]
  [[ "${output}" == *"# name: phone"* ]]
  [[ "${output}" == *"PrivateKey = SERVER_PRIV_FIXTURE"* ]]
  # Removing the last peer leaves no trailing blank lines.
  run remove_peer_section phone <"${SERVER_FIXTURES}/wg0-two-peers.conf"
  [ "$(last_lines "${output}" 1)" = "AllowedIPs = 10.66.0.2/32" ]
}

@test "list_peers prints name, address and public key per peer" {
  run list_peers "${SERVER_FIXTURES}/wg0-two-peers.conf"
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf 'mac\t10.66.0.2\tPUB_MAC\nphone\t10.66.0.4\tPUB_PHONE')" ]
}

@test "gen_keys: deterministic placeholders in dry-run, real keys with wg" {
  DRY_RUN=1
  gen_keys
  [ "${WG_PRIVKEY}" = "DRYRUN_PRIVATE_KEY_1" ]
  [ "${WG_PUBKEY}" = "DRYRUN_PUBLIC_KEY_1" ]
  gen_keys
  [ "${WG_PRIVKEY}" = "DRYRUN_PRIVATE_KEY_2" ]
  [ "${WG_PUBKEY}" = "DRYRUN_PUBLIC_KEY_2" ]
  # With wg installed (Linux CI), outside dry-run the keys are real.
  command -v wg >/dev/null 2>&1 || return 0
  DRY_RUN=0
  gen_keys
  [ "${#WG_PRIVKEY}" -eq 44 ]
  [ "$(printf '%s\n' "${WG_PRIVKEY}" | wg pubkey)" = "${WG_PUBKEY}" ]
}
