#!/usr/bin/env bats
# wgconf.sh and common.sh helpers.

load ../helpers/client_helpers

setup() {
  client_test_env
  load_client_libs
}

@test "parse_wg_conf reads endpoint, address, DNS and peer key" {
  run parse_wg_conf "${PEER_CONF}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ENDPOINT_HOST=203.0.113.5"* ]]
  [[ "${output}" == *"ENDPOINT_PORT=51820"* ]]
  [[ "${output}" == *"ADDRESS=10.66.0.2/32"* ]]
  [[ "${output}" == *"DNS=10.66.0.1"* ]]
  [[ "${output}" == *"PEER_PUBLIC_KEY=FAKEserverPUBLICkeyFAKEserverPUBLICkeyFAKE00="* ]]
  [[ "${output}" == *"PRIVATE_KEY_PRESENT=yes"* ]]
}

@test "parse_wg_conf never prints the private key" {
  run parse_wg_conf "${PEER_CONF}"
  [[ "${output}" != *"FAKEprivateKEY"* ]]
  run wg_conf_value "${PEER_CONF}" PrivateKey
  [ "${status}" -eq 2 ]
  [[ "${output}" != *"FAKEprivateKEY"* ]]
}

@test "parse_wg_conf splits a hostname endpoint and reports a missing private key" {
  conf="${BATS_TEST_TMPDIR}/host.conf"
  printf '%s\n' "[Interface]" "Address = 10.66.0.3/32" "[Peer]" \
    "PublicKey = abc=" "Endpoint = vpn.example.com:443" >"${conf}"
  run parse_wg_conf "${conf}"
  [[ "${output}" == *"ENDPOINT_HOST=vpn.example.com"* ]]
  [[ "${output}" == *"ENDPOINT_PORT=443"* ]]
  [[ "${output}" == *"PRIVATE_KEY_PRESENT=no"* ]]
}

@test "wg_conf_value returns a single value case-insensitively" {
  run wg_conf_value "${PEER_CONF}" endpoint
  [ "${status}" -eq 0 ]
  [ "${output}" = "203.0.113.5:51820" ]
}

@test "resolve_host passes an IPv4 address through unchanged" {
  run resolve_host 203.0.113.5
  [ "${status}" -eq 0 ]
  [ "${output}" = "203.0.113.5" ]
}

@test "boot_volume_is_external: internal, external location, USB protocol" {
  FAKE_DISK=internal run boot_volume_is_external
  [ "${status}" -eq 1 ]
  FAKE_DISK=external run boot_volume_is_external
  [ "${status}" -eq 0 ]
  FAKE_DISK=usb run boot_volume_is_external
  [ "${status}" -eq 0 ]
  FAKE_DISK=fail run boot_volume_is_external
  [ "${status}" -eq 2 ]
}

@test "network_services drops the header and disabled services" {
  run network_services
  [ "${status}" -eq 0 ]
  [ "${output}" = "Wi-Fi
USB 10/100/1000 LAN" ]
}

@test "phys_ifaces lists en* devices and falls back to en0" {
  run phys_ifaces
  [ "${output}" = "en0 en7" ]
  FAKE_NO_PORTS=1 run phys_ifaces
  [ "${output}" = "en0" ]
}

@test "run and write_file only print in dry-run" {
  export DRY_RUN=1
  run oneexit_run rm -rf "${BATS_TEST_TMPDIR}/keep me"
  [ "${output}" = "[dry-run] rm -rf '${BATS_TEST_TMPDIR}/keep me'" ]
  [ -d "${BATS_TEST_TMPDIR}" ]
  run write_file "${BATS_TEST_TMPDIR}/new.txt" 0644 <<<"hello"
  [[ "${output}" == *"[dry-run] write ${BATS_TEST_TMPDIR}/new.txt (mode 0644)"* ]]
  [[ "${output}" == *"| hello"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/new.txt" ]
}
