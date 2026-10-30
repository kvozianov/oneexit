#!/usr/bin/env bats
# render_pf and friends: exact rulesets, no extra holes.

load ../helpers/client_helpers

setup() {
  client_test_env
  load_client_libs
}

@test "render_pf prints the exact contract ruleset for one interface" {
  run render_pf 203.0.113.5 51820 utun3 en0
  [ "${status}" -eq 0 ]
  expected="# oneexit kill switch (generated; do not edit)
set block-policy drop
pass quick on lo0 all no state
block all
block quick inet6 all
pass out quick on { en0 } proto udp from any to 203.0.113.5 port 51820 keep state
pass out quick on { en0 } proto udp from port 68 to port 67 keep state
pass in quick on { en0 } proto udp from port 67 to port 68 keep state
pass out quick on utun3 proto { tcp udp icmp } all keep state
pass in quick on utun3 proto icmp all keep state"
  [ "${output}" = "${expected}" ]
}

@test "render_pf defaults to en0 when no interface is given" {
  run render_pf 203.0.113.5 51820 utun3
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(render_pf 203.0.113.5 51820 utun3 en0)" ]
}

@test "render_pf lists several interfaces in one set" {
  run render_pf 198.51.100.7 443 utun0 en0 en1 en7
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"pass out quick on { en0 en1 en7 } proto udp from any to 198.51.100.7 port 443 keep state"* ]]
  [ "$(printf '%s\n' "${output}" | grep -c '{ en0 en1 en7 }')" -eq 3 ]
}

@test "render_pf passes nothing on physical interfaces except endpoint and DHCP" {
  run render_pf 203.0.113.5 51820 utun3 en0 en1
  [ "${status}" -eq 0 ]
  phys="$(printf '%s\n' "${output}" | grep '^pass' | grep -v -e ' on utun3 ' -e '^pass quick on lo0 all no state$')"
  [ "$(printf '%s\n' "${phys}" | wc -l | tr -d ' ')" -eq 3 ]
  while IFS= read -r line; do
    case "${line}" in
      *"to 203.0.113.5 port 51820 keep state") ;;
      *"from port 68 to port 67 keep state") ;;
      *"from port 67 to port 68 keep state") ;;
      *) echo "unexpected rule: ${line}"; return 1 ;;
    esac
  done <<<"${phys}"
  [[ "${output}" != *"pass all"* ]]
}

@test "render_pf blocks all IPv6 and passes loopback explicitly" {
  run render_pf 203.0.113.5 51820 utun3 en0
  printf '%s\n' "${output}" | grep -qx 'block quick inet6 all'
  printf '%s\n' "${output}" | grep -qx 'block all'
  printf '%s\n' "${output}" | grep -qx 'pass quick on lo0 all no state'
  [[ "${output}" != *"set skip"* ]]
}

@test "render_pf rejects a hostname, a bad port, a bad tunnel and a bad interface" {
  run render_pf vpn.example.com 51820 utun3 en0
  [ "${status}" -eq 2 ]
  run render_pf 203.0.113.5 70000 utun3 en0
  [ "${status}" -eq 2 ]
  run render_pf 203.0.113.5 51820 en0
  [ "${status}" -eq 2 ]
  run render_pf 203.0.113.5 51820 utun en0
  [ "${status}" -eq 2 ]
  run render_pf 203.0.113.5 51820 utun3 'en0;pass'
  [ "${status}" -eq 2 ]
}

@test "render_pf_portal adds 80/443 and udp 53 before the utun lines" {
  run render_pf_portal 203.0.113.5 51820 utun3 en0
  [ "${status}" -eq 0 ]
  web="pass out quick on { en0 } proto tcp from any to any port { 80 443 } keep state"
  dns="pass out quick on { en0 } proto udp from any to any port 53 keep state"
  [ "$(printf '%s\n' "${output}" | sed -n 9p)" = "${web}" ]
  [ "$(printf '%s\n' "${output}" | sed -n 10p)" = "${dns}" ]
  [ "$(printf '%s\n' "${output}" | sed -n 11p)" = "pass out quick on utun3 proto { tcp udp icmp } all keep state" ]
  printf '%s\n' "${output}" | grep -qx 'block quick inet6 all'
  [ "$(printf '%s\n' "${output}" | wc -l | tr -d ' ')" -eq 12 ]
}

@test "render_pf_unlocked prints pass all" {
  run render_pf_unlocked
  [ "${status}" -eq 0 ]
  [ "${output}" = "pass all" ]
}

@test "render_pf_failsafe passes loopback and DHCP only, no tunnel" {
  run render_pf_failsafe
  [ "${status}" -eq 0 ]
  printf '%s\n' "${output}" | grep -qx 'pass quick on lo0 all no state'
  printf '%s\n' "${output}" | grep -qx 'block all'
  [[ "${output}" != *"utun"* ]]
  [ "$(printf '%s\n' "${output}" | grep -c '^pass')" -eq 3 ]
}

@test "tunnel_iface_or_placeholder reads wg0.name, else falls back to utun99" {
  run tunnel_iface_or_placeholder
  [ "${output}" = "utun99" ]
  ONEEXIT_WG_RUN_DIR="${FIXTURES}/wireguard" run tunnel_iface_or_placeholder
  [ "${output}" = "utun3" ]
  echo "en0" >"${ONEEXIT_WG_RUN_DIR}/wg0.name"
  run tunnel_iface_or_placeholder
  [ "${output}" = "utun99" ]
}

@test "pf_render_mode uses the live utun, or the placeholder while the tunnel is down" {
  write_test_config
  load_config
  run pf_render_mode locked
  [[ "${output}" == *"pass out quick on utun99 proto { tcp udp icmp } all keep state"* ]]
  ONEEXIT_WG_RUN_DIR="${FIXTURES}/wireguard" run pf_render_mode locked
  [ "${output}" = "$(render_pf 203.0.113.5 51820 utun3 en0)" ]
}

@test "pf_main_has_hook: present, missing, unreadable" {
  FAKE_PFCTL=hook run pf_main_has_hook
  [ "${status}" -eq 0 ]
  FAKE_PFCTL=nohook run pf_main_has_hook
  [ "${status}" -eq 1 ]
  FAKE_PFCTL=denied run pf_main_has_hook
  [ "${status}" -eq 2 ]
}

@test "pf_conf_has_hook checks /etc/pf.conf for anchor com.apple/*" {
  run pf_conf_has_hook "${FIXTURES}/pf.conf"
  [ "${status}" -eq 0 ]
  run pf_conf_has_hook "${FIXTURES}/pf.conf.nohook"
  [ "${status}" -eq 1 ]
  run pf_conf_has_hook "${BATS_TEST_TMPDIR}/missing"
  [ "${status}" -eq 2 ]
}

@test "pf_current_mode honours unlock and portal timers and ignores expired ones" {
  now=1000000
  run pf_current_mode "${now}"
  [ "${output}" = "locked" ]
  echo 1000300 >"${ONEEXIT_RUN_DIR}/portal-until"
  run pf_current_mode "${now}"
  [ "${output}" = "portal 1000300" ]
  echo 1000600 >"${ONEEXIT_RUN_DIR}/unlock-until"
  run pf_current_mode "${now}"
  [ "${output}" = "unlocked 1000600" ]
  run pf_current_mode 2000000
  [ "${output}" = "locked" ]
}

@test "pfctl_quiet drops macOS's ALTQ and -f chatter, keeps real messages and the exit status" {
  FAKE_PFCTL=noisy run pfctl_quiet -a com.apple/oneexit -f /dev/null
  [ "${status}" -eq 0 ]
  [ "${output}" = "pfctl: real problem on line 3" ]
  FAKE_PFCTL=noisy FAKE_PFCTL_RC=1 run pf_load_ruleset /dev/null
  [ "${status}" -eq 1 ]
  [[ "${output}" != *"ALTQ"* ]]
}
