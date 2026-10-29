#!/usr/bin/env bats
# shellcheck disable=SC2034  # DRY_RUN is read by the sourced server libraries
# Helpers in server/lib/common.sh.

load ../helpers/server_helpers

setup() {
  server_setup
  load_server_libs
}

@test "run() and write_file print in dry-run, execute and write atomically otherwise" {
  DRY_RUN=1
  run oneexit_run touch "${BATS_TEST_TMPDIR}/a file"
  [ "${output}" = "[dry-run] touch ${BATS_TEST_TMPDIR}/a\\ file" ]
  [ ! -e "${BATS_TEST_TMPDIR}/a file" ]
  DRY_RUN=0
  run oneexit_run touch "${BATS_TEST_TMPDIR}/a file"
  [ "${status}" -eq 0 ]
  [ -e "${BATS_TEST_TMPDIR}/a file" ]

  target="${BATS_TEST_TMPDIR}/sub/file.conf"
  DRY_RUN=1
  run write_file "${target}" 0600 <<<"hello"
  [ "${output}" = "$(printf '[dry-run] write %s (mode 0600):\nhello' "${target}")" ]
  [ ! -e "${target}" ]
  DRY_RUN=0
  write_file "${target}" 0640 <<<"hello" 2>/dev/null
  [ "$(cat "${target}")" = "hello" ]
  mode="$(stat -c '%a' "${target}" 2>/dev/null || stat -f '%Lp' "${target}")"
  [ "${mode}" = "640" ]
  [ -z "$(find "${BATS_TEST_TMPDIR}/sub" -name '.oneexit.*')" ]
}

@test "detect_os accepts Debian 12 and Ubuntu 22.04+, rejects older and other systems" {
  mkdir -p "${ONEEXIT_ROOT}/etc"
  os_release() { printf 'ID=%s\nVERSION_ID="%s"\n' "$1" "$2" >"${ONEEXIT_ROOT}/etc/os-release"; }
  os_release debian 12
  run detect_os
  [ "${status}" -eq 0 ]
  [ "${output}" = "Debian 12" ]
  os_release ubuntu 24.04
  run detect_os
  [ "${status}" -eq 0 ]
  [ "${output}" = "Ubuntu 24.04" ]
  os_release ubuntu 20.04
  run detect_os
  [ "${status}" -eq 1 ]
  os_release debian 11
  run detect_os
  [ "${status}" -eq 1 ]
  os_release fedora 40
  run detect_os
  [ "${status}" -eq 1 ]
  # Not root, but dry-run: require_root does not stop the script.
  DRY_RUN=1
  run require_root
  [ "${status}" -eq 0 ]
}
