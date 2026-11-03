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
    /etc/systemd/system/oneexit-nft.service /etc/unbound/unbound.conf.d/oneexit.conf \
    /etc/wireguard/peers/mac.conf; do
    [[ "${output}" == *"[dry-run] write ${ONEEXIT_ROOT}${f} "* ]]
  done
  # /etc/nftables.conf and nftables.service are never touched.
  [[ "${output}" != *"[dry-run] write ${ONEEXIT_ROOT}/etc/nftables.conf"* ]]
  [[ "${output}" != *"systemctl enable nftables"* ]]
  [ -z "$(find "${ONEEXIT_ROOT}" -type f)" ]
}

@test "install.sh --dry-run --port 443 prints packages, services, port, peer config and QR" {
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5 --peer ci --port 443
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=600 update -q"* ]]
  [[ "${output}" == *"env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=600 install -y -q wireguard wireguard-tools unbound nftables qrencode dnsutils"* ]]
  [[ "${output}" == *"[dry-run] systemctl enable --now wg-quick@wg0"* ]]
  [[ "${output}" == *"[dry-run] systemctl enable unbound"* ]]
  [[ "${output}" == *"$(printf '[dry-run] systemctl daemon-reload\n[dry-run] systemctl enable --now oneexit-nft.service')"* ]]
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

@test "install.sh --dry-run writes the oneexit-nft unit and removes an old nftables.conf include" {
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [ "${status}" -eq 0 ]
  for line in 'Type=oneshot' 'RemainAfterExit=yes' 'ExecStart=/usr/sbin/nft -f /etc/nftables.d/oneexit.nft' \
    'ExecStop=-/usr/sbin/nft delete table inet oneexit' 'ExecStop=-/usr/sbin/nft delete table ip oneexit_nat' \
    'After=network-pre.target' 'Wants=network-pre.target' 'WantedBy=multi-user.target'; do
    [[ "${output}" == *"${line}"* ]]
  done
  # A stock nftables.conf is left alone.
  mkdir -p "${ONEEXIT_ROOT}/etc"
  printf '#!/usr/sbin/nft -f\nflush ruleset\n' >"${ONEEXIT_ROOT}/etc/nftables.conf"
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [[ "${output}" != *"[dry-run] write ${ONEEXIT_ROOT}/etc/nftables.conf"* ]]
  # The include line an earlier version appended is removed.
  printf '\n# oneexit (server/install.sh): WireGuard firewall and NAT\ninclude "/etc/nftables.d/oneexit.nft"\n' \
    >>"${ONEEXIT_ROOT}/etc/nftables.conf"
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [[ "${output}" == *"$(printf '[dry-run] write %s/etc/nftables.conf (mode 0755):\n#!/usr/sbin/nft -f\nflush ruleset\nok: removed the old oneexit include line' "${ONEEXIT_ROOT}")"* ]]
}

@test "install.sh --timezone is validated, written to oneexit.env, the peer config and the summary" {
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5 --timezone Europe/Berlin
  [ "${status}" -eq 0 ]
  expected="$(printf '[dry-run] write %s/etc/wireguard/oneexit.env (mode 0600):\nENDPOINT=203.0.113.5\nPORT=51820\nTIMEZONE=Europe/Berlin' "${ONEEXIT_ROOT}")"
  [[ "${output}" == *"${expected}"* ]]
  [[ "${output}" == *"$(printf '(mode 0600):\n# oneexit-timezone = Europe/Berlin\n[Interface]')"* ]]
  [[ "${output}" == *"Time zone     Europe/Berlin"* ]]
  # Validation against the tz database (a fixture directory here).
  export ONEEXIT_ZONEINFO="${BATS_TEST_TMPDIR}/zoneinfo"
  mkdir -p "${ONEEXIT_ZONEINFO}/Europe"
  : >"${ONEEXIT_ZONEINFO}/Europe/Berlin"
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5 --timezone Europe/Berlin
  [ "${status}" -eq 0 ]
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5 --timezone Mars/Olympus
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"invalid --timezone: Mars/Olympus"* ]]
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5 --timezone ../../etc/passwd
  [ "${status}" -eq 2 ]
  # Without a tz database only the form of the name is checked.
  export ONEEXIT_ZONEINFO="${BATS_TEST_TMPDIR}/missing"
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5 --timezone 'Europe/Ber lin'
  [ "${status}" -eq 2 ]
}

@test "install.sh detects the server time zone: timedatectl, then /etc/timezone, then Etc/UTC" {
  stubs="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${stubs}"
  printf '#!/bin/sh\n[ "$*" = "show -p Timezone --value" ] && echo Asia/Tokyo\n' >"${stubs}/timedatectl"
  chmod +x "${stubs}/timedatectl"
  PATH="${stubs}:${PATH}" run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"TIMEZONE=Asia/Tokyo"* ]]
  [[ "${output}" == *"# oneexit-timezone = Asia/Tokyo"* ]]
  # timedatectl fails: /etc/timezone is used.
  printf '#!/bin/sh\nexit 1\n' >"${stubs}/timedatectl"
  mkdir -p "${ONEEXIT_ROOT}/etc"
  printf 'America/New_York\n' >"${ONEEXIT_ROOT}/etc/timezone"
  PATH="${stubs}:${PATH}" run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [[ "${output}" == *"TIMEZONE=America/New_York"* ]]
  # Neither: Etc/UTC.
  rm "${ONEEXIT_ROOT}/etc/timezone"
  PATH="${stubs}:${PATH}" run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"TIMEZONE=Etc/UTC"* ]]
  # A re-run keeps the time zone recorded in oneexit.env; --timezone replaces it.
  install_wg_fixture wg0-two-peers.conf
  printf 'TIMEZONE=Europe/Paris\n' >>"${ONEEXIT_ROOT}/etc/wireguard/oneexit.env"
  PATH="${stubs}:${PATH}" run "${INSTALL_SH}" --dry-run
  [[ "${output}" == *"$(printf 'ENDPOINT=vpn.example.org\nPORT=443\nTIMEZONE=Europe/Paris')"* ]]
  PATH="${stubs}:${PATH}" run "${INSTALL_SH}" --dry-run --timezone Europe/Berlin
  [[ "${output}" == *"time zone changed from Europe/Paris to Europe/Berlin"* ]]
  [[ "${output}" == *"$(printf 'PORT=443\nTIMEZONE=Europe/Berlin')"* ]]
}

@test "install.sh blocks gs-loc.apple.com in unbound unless --no-dns-blocklist" {
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'local-zone: "gs-loc.apple.com." always_nxdomain'* ]]
  run "${INSTALL_SH}" --dry-run --endpoint 203.0.113.5 --no-dns-blocklist
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"local-zone:"* ]]
  [[ "${output}" == *"no blocklist"* ]]
}
