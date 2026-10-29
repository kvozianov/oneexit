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
  export ONEEXIT_NO_SUDO=1
  mkdir -p "${ONEEXIT_ETC_DIR}" "${ONEEXIT_RUN_DIR}" "${ONEEXIT_WG_RUN_DIR}"
  unset DRY_RUN FAKE_DISK FAKE_NO_PORTS FAKE_PFCTL TUN_IFACE
}

# write_test_config [VPS_IP]: a config as setup.sh would write it.
write_test_config() {
  printf '%s\n' "VPS_IP=${1:-203.0.113.5}" "VPS_PORT=51820" \
    "WG_IFACE_CONF=${ONEEXIT_WG_CONF}" 'PHYS_IFACES="en0"' "TUNNEL_DNS=10.66.0.1" \
    >"${ONEEXIT_CONFIG}"
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
  eval "oneexit_run() $(declare -f run | sed 1d)"
  eval "${bats_run}"
}
