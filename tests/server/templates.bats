#!/usr/bin/env bats
# Config templates in server/lib/templates.sh.

load ../helpers/server_helpers

setup() {
  server_setup
  load_server_libs
}

@test "nftables template masquerades the subnet out of the given interface and opens the port" {
  run render_nftables_conf 443 ens3
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'ip saddr 10.66.0.0/24 oifname "ens3" masquerade'* ]]
  [[ "${output}" == *"udp dport 443 accept"* ]]
  [[ "${output}" != *"udp dport 51820"* ]]
  [[ "${output}" == *'iifname "wg0" ip saddr 10.66.0.0/24 udp dport 53 accept'* ]]
  [[ "${output}" == *'iifname "wg0" ip saddr 10.66.0.0/24 tcp dport 53 accept'* ]]
}

@test "nftables template only touches its own tables and is re-runnable" {
  run render_nftables_conf 51820 eth0
  [[ "${output}" != *"flush ruleset"* ]]
  tables="$(printf '%s\n' "${output}" | awk '$1 == "table" || $1 == "delete" { print }' | sort -u)"
  expected="$(printf '%s\n' \
    'delete table inet oneexit' \
    'delete table ip oneexit_nat' \
    'table inet oneexit' \
    'table inet oneexit {' \
    'table ip oneexit_nat' \
    'table ip oneexit_nat {' | sort -u)"
  [ "${tables}" = "${expected}" ]
}

@test "unbound template binds 10.66.0.1 only, is recursive and validates DNSSEC" {
  run render_unbound_conf
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | grep -c '^[[:space:]]*interface:')" -eq 1 ]
  [[ "${output}" == *"interface: 10.66.0.1"* ]]
  [[ "${output}" == *"port: 53"* ]]
  [[ "${output}" != *"forward-zone"* ]]
  [[ "${output}" != *"forward-addr"* ]]
  [[ "${output}" == *"access-control: 10.66.0.0/24 allow"* ]]
  [[ "${output}" == *"access-control: 0.0.0.0/0 refuse"* ]]
  [[ "${output}" == *"do-ip6: no"* ]]
  for opt in 'auto-trust-anchor-file: "/var/lib/unbound/root.key"' \
    'qname-minimisation: yes' 'hide-identity: yes' 'hide-version: yes' 'prefetch: yes'; do
    [[ "${output}" == *"${opt}"* ]]
  done
  run render_unbound_conf no
  [[ "${output}" != *"auto-trust-anchor-file:"* ]]
}

@test "sysctl template enables IPv4 forwarding" {
  run render_sysctl_conf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"net.ipv4.ip_forward=1"* ]]
}
