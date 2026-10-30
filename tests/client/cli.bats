#!/usr/bin/env bats
# The oneexit CLI, the daemons in --once --dry-run, leak-test.sh and plists.

load ../helpers/client_helpers

setup() {
  client_test_env
}

@test "oneexit --help lists every subcommand" {
  run "${CLIENT_DIR}/oneexit" --help
  [ "${status}" -eq 0 ]
  for cmd in status lock unlock portal up down leak-test doctor logs uninstall version; do
    printf '%s\n' "${output}" | grep -Eq "^  ${cmd}( |$)" || {
      echo "missing: ${cmd}"
      return 1
    }
  done
}

@test "oneexit version prints the version; unknown command is a usage error" {
  run "${CLIENT_DIR}/oneexit" version
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ ^oneexit\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
  run "${CLIENT_DIR}/oneexit" frobnicate
  [ "${status}" -eq 2 ]
}

@test "oneexit runs through a symlink (installed-style)" {
  mkdir -p "${BATS_TEST_TMPDIR}/path"
  ln -s "${CLIENT_DIR}/oneexit" "${BATS_TEST_TMPDIR}/path/oneexit"
  run "${BATS_TEST_TMPDIR}/path/oneexit" version
  [ "${status}" -eq 0 ]
}

@test "oneexit unlock --dry-run opens a window, loads pass all and hands DNS to DHCP" {
  write_test_config
  run "${CLIENT_DIR}/oneexit" unlock --minutes 5 --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] write ${ONEEXIT_RUN_DIR}/unlock-until"* ]]
  [[ "${output}" == *"| pass all"* ]]
  [[ "${output}" == *"[dry-run] networksetup -setdnsservers Wi-Fi empty"* ]]
  [ ! -e "${ONEEXIT_RUN_DIR}/unlock-until" ]
  run "${CLIENT_DIR}/oneexit" unlock --minutes 0 --dry-run
  [ "${status}" -eq 2 ]
}

@test "oneexit portal --dry-run loads the portal ruleset and takes the tunnel down" {
  write_test_config
  run "${CLIENT_DIR}/oneexit" --dry-run portal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] write ${ONEEXIT_RUN_DIR}/portal-until"* ]]
  [[ "${output}" == *"port { 80 443 } keep state"* ]]
  [[ "${output}" == *"[dry-run] wg-quick down ${ONEEXIT_WG_CONF}"* ]]
  [[ "${output}" == *"[dry-run] networksetup -setdnsservers Wi-Fi empty"* ]]
}

@test "oneexit lock --dry-run ends both windows and restores tunnel DNS" {
  write_test_config
  run "${CLIENT_DIR}/oneexit" lock --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] rm -f ${ONEEXIT_RUN_DIR}/unlock-until ${ONEEXIT_RUN_DIR}/portal-until"* ]]
  [[ "${output}" == *"[dry-run] pfctl -a com.apple/oneexit -f ${ONEEXIT_ANCHOR_FILE}"* ]]
  [[ "${output}" == *"[dry-run] networksetup -setdnsservers Wi-Fi 10.66.0.1"* ]]
}

@test "oneexit-tunneld keeps the tunnel down during a portal window" {
  write_test_config
  echo $(($(date +%s) + 120)) >"${ONEEXIT_RUN_DIR}/portal-until"
  run "${CLIENT_DIR}/bin/oneexit-tunneld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] wg-quick down ${ONEEXIT_WG_CONF}"* ]]
  [[ "${output}" != *"wg-quick up"* ]]
}

@test "oneexit-tunneld sees a running tunnel via wg0.name + socket and leaves it alone" {
  write_test_config
  ONEEXIT_WG_RUN_DIR="${FIXTURES}/wireguard" run "${CLIENT_DIR}/bin/oneexit-tunneld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tunnel is up on utun3"* ]]
  [[ "${output}" != *"wg-quick up"* ]]
  [[ "${output}" != *"wg-quick down"* ]]
}

@test "oneexit-tunneld brings the tunnel up when no window is open" {
  write_test_config
  run "${CLIENT_DIR}/bin/oneexit-tunneld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] wg-quick up ${ONEEXIT_WG_CONF}"* ]]
}

@test "oneexit-firewalld relocks and restores DNS after the portal window expires" {
  write_test_config
  echo $(($(date +%s) - 10)) >"${ONEEXIT_RUN_DIR}/portal-until"
  run "${CLIENT_DIR}/bin/oneexit-firewalld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] rm -f ${ONEEXIT_RUN_DIR}/portal-until"* ]]
  [[ "${output}" == *"[dry-run] write ${ONEEXIT_ANCHOR_FILE} (mode 0644)"* ]]
  [[ "${output}" == *"[dry-run] pfctl -a com.apple/oneexit -f ${ONEEXIT_ANCHOR_FILE}"* ]]
  [[ "${output}" == *"[dry-run] networksetup -setdnsservers Wi-Fi 10.66.0.1"* ]]
  [[ "${output}" != *"port { 80 443 }"* ]]
}

@test "oneexit-firewalld re-renders the anchor from the current config" {
  write_test_config 198.51.100.9
  run "${CLIENT_DIR}/bin/oneexit-firewalld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"| pass out quick on { en0 } proto udp from any to 198.51.100.9 port 51820 keep state"* ]]
  [[ "${output}" != *"setdnsservers"* ]]
}

@test "oneexit-firewalld renders the live utun device from wg0.name" {
  write_test_config
  ONEEXIT_WG_RUN_DIR="${FIXTURES}/wireguard" run "${CLIENT_DIR}/bin/oneexit-firewalld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tunnel interface: utun3"* ]]
  [[ "${output}" == *"| pass out quick on utun3 proto { tcp udp icmp } all keep state"* ]]
  [[ "${output}" == *"[dry-run] write ${ONEEXIT_RUN_DIR}/current.pf"* ]]
}

@test "oneexit-firewalld does not reload when current.pf matches the rendered ruleset" {
  write_test_config
  (
    load_client_libs
    load_config
    render_pf 203.0.113.5 51820 utun99 en0 >"${ONEEXIT_RUN_DIR}/current.pf"
  )
  FAKE_PFCTL=hook run "${CLIENT_DIR}/bin/oneexit-firewalld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"pfctl -a com.apple/oneexit -f"* ]]
  ONEEXIT_WG_RUN_DIR="${FIXTURES}/wireguard" FAKE_PFCTL=hook \
    run "${CLIENT_DIR}/bin/oneexit-firewalld" --once --dry-run
  [[ "${output}" == *"ruleset changed"* ]]
  [[ "${output}" == *"[dry-run] pfctl -a com.apple/oneexit -f ${ONEEXIT_ANCHOR_FILE}"* ]]
}

@test "oneexit-firewalld with PHYS_IFACES=auto uses the live hardware ports" {
  write_test_config 203.0.113.5 auto
  run "${CLIENT_DIR}/bin/oneexit-firewalld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"| pass out quick on { en0 en7 } proto udp from any to 203.0.113.5 port 51820 keep state"* ]]
}

@test "oneexit-firewalld logs and repairs a missing com.apple/* hook" {
  write_test_config
  FAKE_PFCTL=nohook run "${CLIENT_DIR}/bin/oneexit-firewalld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'error: main pf ruleset has no "com.apple/*" anchor; the kill switch is not active'* ]]
  [[ "${output}" == *"[dry-run] pfctl -f ${ONEEXIT_PF_CONF}"* ]]
  [[ "${output}" == *"[dry-run] pfctl -a com.apple/oneexit -f ${ONEEXIT_ANCHOR_FILE}"* ]]
  FAKE_PFCTL=hook run "${CLIENT_DIR}/bin/oneexit-firewalld" --once --dry-run
  [[ "${output}" != *"kill switch is not active"* ]]
}

@test "oneexit-firewalld fails closed without a config" {
  run "${CLIENT_DIR}/bin/oneexit-firewalld" --once --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"failsafe"* ]]
  [[ "${output}" == *"| block all"* ]]
  [[ "${output}" == *"| pass quick on lo0 all no state"* ]]
}

@test "leak-test.sh --dry-run exits 0 and runs nothing" {
  run "${REPO_ROOT}/scripts/leak-test.sh" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] curl -6 -s -m 5 https://api64.ipify.org"* ]]
  [[ "${output}" == *"[dry-run] dig +short"*"whoami.akamai.net"* ]]
  [[ "${output}" == *"[dry-run] pfctl -s rules"* ]]
  [[ "${output}" == *"[dry-run] route -n get default"* ]]
  [ "$(printf '%s\n' "${output}" | grep -Ec '^(PASS|FAIL|SKIP|INFO) ')" -eq 8 ]
}

@test "leak-test.sh --dry-run --json prints a valid JSON array of 8 checks" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  run bash -c '"$1" --dry-run --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d)==8, d; print(d[0][\"check\"])"' _ "${REPO_ROOT}/scripts/leak-test.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "pf" ]
}

@test "leak-test ipv6: an IPv4-mapped answer to curl -6 is not IPv6 connectivity" {
  write_test_config
  run "${REPO_ROOT}/scripts/leak-test.sh"
  printf '%s\n' "${output}" | grep -q '^PASS  ipv6 .*IPv4-mapped'
  FAKE_CURL_IPV6=none run "${REPO_ROOT}/scripts/leak-test.sh"
  printf '%s\n' "${output}" | grep -q '^PASS  ipv6       no IPv6 connectivity$'
}

@test "leak-test ipv6: an IPv6 answer or a connection to an IPv6 literal fails" {
  write_test_config
  FAKE_CURL_IPV6=v6 run "${REPO_ROOT}/scripts/leak-test.sh"
  [ "${status}" -eq 1 ]
  printf '%s\n' "${output}" | grep -q '^FAIL  ipv6 .*2001:db8::5'
  FAKE_CURL_IPV6=literal run "${REPO_ROOT}/scripts/leak-test.sh"
  [ "${status}" -eq 1 ]
  printf '%s\n' "${output}" | grep -q '^FAIL  ipv6 .*2606:4700:4700::1111'
}

@test "leak-test direct: with the tunnel routes up it probes the on-link gateway" {
  write_test_config
  run "${REPO_ROOT}/scripts/leak-test.sh"
  printf '%s\n' "${output}" | grep -q '^PASS  direct .*gateway 192.168.1.1'
  FAKE_CURL_GW=refused run "${REPO_ROOT}/scripts/leak-test.sh"
  [ "${status}" -eq 1 ]
  printf '%s\n' "${output}" | grep -q '^FAIL  direct .*reached the gateway 192.168.1.1'
}

@test "leak-test direct: a timeout passes, an answer from 1.1.1.1 fails" {
  write_test_config
  FAKE_CURL_DIRECT=timeout run "${REPO_ROOT}/scripts/leak-test.sh"
  printf '%s\n' "${output}" | grep -q '^PASS  direct     requests bound to en0 are dropped$'
  FAKE_CURL_DIRECT=open run "${REPO_ROOT}/scripts/leak-test.sh"
  [ "${status}" -eq 1 ]
  printf '%s\n' "${output}" | grep -q '^FAIL  direct .*reached 1.1.1.1'
}

@test "leak-test --expect-ip is the expected exit for both the ipv4 and dns checks" {
  write_test_config
  FAKE_PUBLIC_IP=198.51.100.7 run "${REPO_ROOT}/scripts/leak-test.sh"
  printf '%s\n' "${output}" | grep -q '^FAIL  ipv4 '
  printf '%s\n' "${output}" | grep -q '^FAIL  dns '
  FAKE_PUBLIC_IP=198.51.100.7 run "${REPO_ROOT}/scripts/leak-test.sh" --expect-ip 198.51.100.7
  printf '%s\n' "${output}" | grep -q '^PASS  ipv4 '
  printf '%s\n' "${output}" | grep -q '^PASS  dns '
  printf '%s\n' "${output}" | grep -q '^INFO  webrtc .*only 198.51.100.7 may appear'
}

@test "oneexit status falls back to the next IPv4 service and skips lookups while the tunnel is down" {
  write_test_config
  run "${CLIENT_DIR}/oneexit" status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"public IPv4:  not checked (tunnel down)"* ]]
  ONEEXIT_WG_RUN_DIR="${FIXTURES}/wireguard" FAKE_CURL_IPIFY=down run "${CLIENT_DIR}/oneexit" status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tunnel:       utun3"* ]]
  [[ "${output}" == *"public IPv4:  203.0.113.5 (your VPS)"* ]]
}

@test "oneexit down --dry-run stops the daemon and the tunnel" {
  write_test_config
  run "${CLIENT_DIR}/oneexit" down --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] launchctl bootout system/com.oneexit.tunnel"* ]]
  [[ "${output}" == *"[dry-run] wg-quick down ${ONEEXIT_WG_CONF}"* ]]
}

@test "the tunnel daemon leaves wireguard-go running when it stops (AbandonProcessGroup)" {
  plist="${CLIENT_DIR}/launchd/com.oneexit.tunnel.plist"
  grep -A1 '<key>AbandonProcessGroup</key>' "${plist}" | grep -q '<true/>'
}

@test "launchd plists pass plutil -lint and point at libexec" {
  command -v plutil >/dev/null 2>&1 || skip "plutil not available (not macOS)"
  for label in com.oneexit.firewall com.oneexit.tunnel; do
    plist="${CLIENT_DIR}/launchd/${label}.plist"
    run plutil -lint "${plist}"
    [ "${status}" -eq 0 ]
    grep -q "<string>${label}</string>" "${plist}"
    grep -q '<string>/usr/local/libexec/oneexit/oneexit-' "${plist}"
    grep -q "<string>/var/log/oneexit/${label#com.oneexit.}.log</string>" "${plist}"
  done
}

@test "client scripts parse with the stock bash" {
  for f in "${CLIENT_DIR}"/setup.sh "${CLIENT_DIR}"/uninstall.sh "${CLIENT_DIR}"/oneexit \
    "${CLIENT_DIR}"/bin/* "${CLIENT_DIR}"/lib/*.sh "${REPO_ROOT}"/scripts/leak-test.sh; do
    /bin/bash -n "${f}"
  done
}
