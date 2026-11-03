# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# Shared setup for tests/client/*.bats.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
CLIENT_DIR="${REPO_ROOT}/client"
FIXTURES="${REPO_ROOT}/tests/client/fixtures"
PEER_CONF="${FIXTURES}/peer.conf"

# client_test_env: stubs first on PATH and every oneexit path in a temp dir,
# so nothing on the host is read or written. The WireGuard run dir starts
# empty (tunnel down); point ONEEXIT_WG_RUN_DIR at fixtures/wireguard for utun3.
client_test_env() {
  export PATH="${FIXTURES}/bin:${PATH}"
  local t="${BATS_TEST_TMPDIR}"
  export ONEEXIT_ETC_DIR="${t}/etc/oneexit"
  export ONEEXIT_CONFIG="${ONEEXIT_ETC_DIR}/config"
  export ONEEXIT_STATE_FILE="${ONEEXIT_ETC_DIR}/state"
  export ONEEXIT_WG_DIR="${t}/etc/wireguard"
  export ONEEXIT_WG_CONF="${ONEEXIT_WG_DIR}/wg0.conf"
  export ONEEXIT_ANCHOR_FILE="${t}/pf.anchors/com.oneexit"
  export ONEEXIT_BIN="${t}/bin/oneexit"
  export ONEEXIT_LIBEXEC="${t}/libexec/oneexit"
  export ONEEXIT_LAUNCHD_DIR="${t}/LaunchDaemons"
  export ONEEXIT_LOG_DIR="${t}/log"
  export ONEEXIT_RUN_DIR="${t}/run"
  export ONEEXIT_WG_RUN_DIR="${t}/wireguard"
  export ONEEXIT_PF_CONF="${FIXTURES}/pf.conf"
  export ONEEXIT_NEWSYSLOG_CONF="${t}/newsyslog.d/oneexit.conf"
  export ONEEXIT_NO_SUDO=1
  # Privacy hardening: state, zone files, /Applications and /etc/localtime
  # in the temp dir; the defaults/scutil/systemsetup/id stubs answer the rest.
  export ONEEXIT_PRIVACY_STATE="${ONEEXIT_ETC_DIR}/privacy-state"
  export ONEEXIT_ZONEINFO="${FIXTURES}/zoneinfo"
  export ONEEXIT_APPLICATIONS_DIR="${t}/Applications"
  export ONEEXIT_LOCALTIME="${t}/localtime"
  export ONEEXIT_PRIVACY_USER="tester"
  mkdir -p "${ONEEXIT_ETC_DIR}" "${ONEEXIT_RUN_DIR}" "${ONEEXIT_WG_RUN_DIR}" "${ONEEXIT_APPLICATIONS_DIR}"
  ln -sf /var/db/timezone/zoneinfo/Asia/Almaty "${ONEEXIT_LOCALTIME}"
  unset DRY_RUN FAKE_DISK FAKE_NO_PORTS FAKE_PFCTL FAKE_PFCTL_RC TUN_IFACE \
    FAKE_PUBLIC_IP FAKE_CURL_IPIFY FAKE_CURL_IPV6 FAKE_CURL_DIRECT FAKE_CURL_GW FAKE_WHOAMI \
    SUDO_USER FAKE_UID FAKE_ID_USER FAKE_ID_FULLNAME FAKE_TIMEZONE FAKE_LOCATION FAKE_TZ_AUTO \
    FAKE_APPLE_LOCALE FAKE_APPLE_LANGUAGES FAKE_WEBRTC FAKE_LOOKUP FAKE_SAFARI \
    FAKE_COMPUTER_NAME FAKE_HOST_NAME FAKE_LOCAL_HOST_NAME FAKE_CALL_LOG \
    SSH_AUTH_SOCK ONEEXIT_SSH_AUTH_SOCK ONEEXIT_REPO_DIR
}

# fake_hardened: stub answers as on a Mac after "oneexit harden --timezone
# Europe/Berlin --region DE" (FAKE_UID=0 to read the root-only values).
fake_hardened() {
  export FAKE_TIMEZONE="Europe/Berlin" FAKE_TZ_AUTO=0 FAKE_LOCATION=0 \
    FAKE_APPLE_LOCALE="ru_DE" FAKE_APPLE_LANGUAGES="ru;en" FAKE_WEBRTC="disable_non_proxied_udp" \
    FAKE_LOOKUP=1 FAKE_SAFARI=0 FAKE_COMPUTER_NAME="Mac" FAKE_HOST_NAME="Mac" FAKE_LOCAL_HOST_NAME="Mac"
  ln -sf /var/db/timezone/zoneinfo/Europe/Berlin "${ONEEXIT_LOCALTIME}"
}

# write_test_config [VPS_IP] [PHYS_IFACES]: a config as setup.sh would write it.
write_test_config() {
  printf '%s\n' "VPS_IP=${1:-203.0.113.5}" "VPS_PORT=51820" \
    "WG_IFACE_CONF=${ONEEXIT_WG_CONF}" "PHYS_IFACES=\"${2:-en0}\"" "TUNNEL_DNS=10.66.0.1" \
    >"${ONEEXIT_CONFIG}"
}

# write_privacy_config [TIMEZONE] [REGION]: write_test_config plus the
# TIMEZONE and REGION lines that setup.sh adds.
write_privacy_config() {
  write_test_config
  printf '%s\n' "TIMEZONE=${1:-Europe/Berlin}" "REGION=${2:-DE}" >>"${ONEEXIT_CONFIG}"
}

# dry_run_block OUTPUT PATH: the "    | " content lines that a dry run printed
# for "[dry-run] write PATH ...".
dry_run_block() {
  printf '%s\n' "$1" | awk -v want="[dry-run] write $2 " '
    index($0, want) == 1 { on = 1; next }
    on && /^    \| / { print substr($0, 7); next }
    on { exit }'
}

# load_client_libs: source the client libraries. common.sh defines run(),
# which would shadow the bats helper of the same name; keep bats' run() and
# expose the library one as oneexit_run().
load_client_libs() {
  local bats_run
  bats_run="$(declare -f run)"
  # shellcheck source=../../client/lib/common.sh
  . "${CLIENT_DIR}/lib/common.sh"
  # shellcheck source=../../client/lib/pf.sh
  . "${CLIENT_DIR}/lib/pf.sh"
  # shellcheck source=../../client/lib/wgconf.sh
  . "${CLIENT_DIR}/lib/wgconf.sh"
  # shellcheck source=../../client/lib/privacy.sh
  . "${CLIENT_DIR}/lib/privacy.sh"
  eval "oneexit_run() $(declare -f run | sed 1d)"
  eval "${bats_run}"
}

# load_init_libs: load_client_libs plus setup_steps.sh and init.sh ("oneexit
# init"); SELF_DIR points at the checkout's client/ as in the CLI.
load_init_libs() {
  load_client_libs
  SELF_DIR="${CLIENT_DIR}"
  # shellcheck source=../../client/lib/setup_steps.sh
  . "${CLIENT_DIR}/lib/setup_steps.sh"
  # shellcheck source=../../client/lib/init.sh
  . "${CLIENT_DIR}/lib/init.sh"
}
