# Shared setup for tests/server/*.bats.
# shellcheck shell=bash

SERVER_DIR="$(cd "${BATS_TEST_DIRNAME}/../../server" && pwd)"
SERVER_FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

# Isolate every test: all system paths are prefixed with a per-test directory,
# and nothing inherited from the caller turns dry-run on or off.
server_setup() {
  unset DRY_RUN
  export ONEEXIT_ROOT="${BATS_TEST_TMPDIR}/root"
  mkdir -p "${ONEEXIT_ROOT}"
}

# common.sh defines run(), which would shadow bats' own run. Keep bats' run
# and expose the library one as oneexit_run.
load_server_libs() {
  local bats_run
  bats_run="$(declare -f run | tail -n +2)"
  # shellcheck source=../../server/lib/common.sh
  source "${SERVER_DIR}/lib/common.sh"
  eval "oneexit_run() $(declare -f run | tail -n +2)"
  eval "run() ${bats_run}"
  # shellcheck source=../../server/lib/wg.sh
  source "${SERVER_DIR}/lib/wg.sh"
  # shellcheck source=../../server/lib/templates.sh
  source "${SERVER_DIR}/lib/templates.sh"
}

# Install a fixture as ${ONEEXIT_ROOT}/etc/wireguard/wg0.conf plus a state
# file and a server public key, as install.sh would leave them.
install_wg_fixture() {
  local fixture="$1"
  mkdir -p "${ONEEXIT_ROOT}/etc/wireguard/peers"
  cp "${SERVER_FIXTURES}/${fixture}" "${ONEEXIT_ROOT}/etc/wireguard/wg0.conf"
  printf 'ENDPOINT=vpn.example.org\nPORT=443\n' >"${ONEEXIT_ROOT}/etc/wireguard/oneexit.env"
  printf 'SERVER_PUB_FIXTURE\n' >"${ONEEXIT_ROOT}/etc/wireguard/server.pub"
}

# Print the last N lines of $1.
last_lines() {
  printf '%s\n' "$1" | tail -n "$2"
}
