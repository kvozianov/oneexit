#!/usr/bin/env bats
# client/setup.sh and client/uninstall.sh in dry-run with stubbed system tools.

load ../helpers/client_helpers

setup() {
  client_test_env
}

@test "setup.sh --dry-run refuses an internal boot disk" {
  FAKE_DISK=internal run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --dry-run
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"internal disk"* ]]
  [[ "${output}" == *"--allow-internal-disk"* ]]
  [[ "${output}" == *"Device Location:           Internal"* ]]
  [[ "${output}" != *"launchctl bootstrap"* ]]
}

@test "setup.sh --dry-run proceeds on an internal disk with --allow-internal-disk" {
  FAKE_DISK=internal run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --allow-internal-disk --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"continuing because of --allow-internal-disk"* ]]
  [[ "${output}" == *"[dry-run] launchctl bootstrap system ${ONEEXIT_LAUNCHD_DIR}/com.oneexit.firewall.plist"* ]]
}

@test "setup.sh --dry-run on an external disk prints every step" {
  FAKE_DISK=external run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"install wireguard-tools wireguard-go"* ]]
  [[ "${output}" == *"[dry-run] write ${ONEEXIT_CONFIG} (mode 0644)"* ]]
  [[ "${output}" == *"| VPS_IP=203.0.113.5"* ]]
  [[ "${output}" == *"| TUNNEL_DNS=10.66.0.1"* ]]
  [[ "${output}" == *'| PHYS_IFACES="en0 en7"'* ]]
  [[ "${output}" == *"install -m 0600 -o root -g wheel ${PEER_CONF} ${ONEEXIT_WG_CONF}"* ]]
  [[ "${output}" == *"[dry-run] write ${ONEEXIT_ANCHOR_FILE} (mode 0644)"* ]]
  [[ "${output}" == *"| pass out quick on { en0 en7 } proto udp from any to 203.0.113.5 port 51820 keep state"* ]]
  [[ "${output}" == *"| pass out quick on utun99 proto { tcp udp icmp } all keep state"* ]]
  [[ "${output}" == *"| PF_WAS_ENABLED=no"* ]]
  [[ "${output}" == *"[dry-run] networksetup -setv6off Wi-Fi"* ]]
  [[ "${output}" == *"[dry-run] networksetup -setv6off 'USB 10/100/1000 LAN'"* ]]
  [[ "${output}" == *"[dry-run] networksetup -setdnsservers Wi-Fi 10.66.0.1"* ]]
  [[ "${output}" != *"Thunderbolt Bridge"* ]]
  [[ "${output}" == *"<string>/usr/local/libexec/oneexit/oneexit-tunneld</string>"* ]]
  [[ "${output}" == *"[dry-run] launchctl bootstrap system ${ONEEXIT_LAUNCHD_DIR}/com.oneexit.tunnel.plist"* ]]
  [[ "${output}" == *"leak-test.sh ${ONEEXIT_LIBEXEC}/leak-test.sh"* ]]
  [ ! -e "${ONEEXIT_CONFIG}" ]
  [ ! -e "${ONEEXIT_ANCHOR_FILE}" ]
}

@test "setup.sh refuses when pf.conf lacks the com.apple/* anchor hook" {
  FAKE_DISK=external ONEEXIT_PF_CONF="${FIXTURES}/pf.conf.nohook" \
    run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --dry-run
  [ "${status}" -eq 1 ]
  [[ "${output}" == *'anchor "com.apple/*"'* ]]
  [[ "${output}" == *"block nothing"* ]]
  [[ "${output}" != *"launchctl bootstrap"* ]]
}

@test "setup.sh --iface overrides interface detection" {
  FAKE_DISK=usb run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --iface en1 --iface en2 --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"| pass out quick on { en1 en2 } proto udp from any to 203.0.113.5 port 51820 keep state"* ]]
}

@test "setup.sh never prints the private key" {
  FAKE_DISK=external run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"FAKEprivateKEY"* ]]
}

@test "setup.sh needs --config and has --help" {
  run "${CLIENT_DIR}/setup.sh" --dry-run
  [ "${status}" -eq 2 ]
  run "${CLIENT_DIR}/setup.sh" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--allow-internal-disk"* ]]
}

@test "uninstall.sh --dry-run lists plists, anchor and network restore" {
  run "${CLIENT_DIR}/uninstall.sh" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] launchctl bootout system/com.oneexit.firewall"* ]]
  [[ "${output}" == *"${ONEEXIT_LAUNCHD_DIR}/com.oneexit.firewall.plist"* ]]
  [[ "${output}" == *"${ONEEXIT_LAUNCHD_DIR}/com.oneexit.tunnel.plist"* ]]
  [[ "${output}" == *"[dry-run] pfctl -a com.apple/oneexit -F all"* ]]
  [[ "${output}" == *"[dry-run] rm -f ${ONEEXIT_ANCHOR_FILE}"* ]]
  [[ "${output}" == *"[dry-run] networksetup -setv6automatic Wi-Fi"* ]]
  [[ "${output}" == *"[dry-run] networksetup -setdnsservers Wi-Fi empty"* ]]
  [[ "${output}" == *"[dry-run] rm -f ${ONEEXIT_WG_CONF}"* ]]
}

@test "uninstall.sh --keep-keys keeps wg0.conf; pfctl -d only if pf was off before" {
  printf 'PF_WAS_ENABLED=no\n' >"${ONEEXIT_STATE_FILE}"
  run "${CLIENT_DIR}/uninstall.sh" --keep-keys --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"rm -f ${ONEEXIT_WG_CONF}"* ]]
  [[ "${output}" == *"[dry-run] pfctl -d"* ]]
  printf 'PF_WAS_ENABLED=yes\n' >"${ONEEXIT_STATE_FILE}"
  run "${CLIENT_DIR}/uninstall.sh" --dry-run
  [[ "${output}" != *"[dry-run] pfctl -d"* ]]
}
