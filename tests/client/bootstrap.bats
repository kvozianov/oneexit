#!/usr/bin/env bats
# The root install.sh (bootstrap for the Mac) and scripts/release-checksum.sh,
# in dry-run and on their refusal paths only: no network, no sudo.

load ../helpers/client_helpers

setup() {
  client_test_env
  export FAKE_CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : >"${FAKE_CALL_LOG}"
  INSTALL="${REPO_ROOT}/install.sh"
  SUM="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}

# pinned_copy [SUM]: install.sh with ONEEXIT_SHA256 set to SUM (default the
# fake one; "" for an unreleased script), so the tests do not depend on
# whether the release step has filled the real value in yet.
pinned_copy() {
  local value="${1-${SUM}}"
  sed "s/^ONEEXIT_SHA256=\"[0-9a-f]*\"/ONEEXIT_SHA256=\"${value}\"/" "${INSTALL}" >"${BATS_TEST_TMPDIR}/install.sh"
  grep -q "^ONEEXIT_SHA256=\"${value}\"$" "${BATS_TEST_TMPDIR}/install.sh"
}

@test "install.sh pins a version and a checksum line for the release step to fill" {
  grep -Eq '^ONEEXIT_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "${INSTALL}"
  grep -Eq '^ONEEXIT_SHA256="([0-9a-f]{64})?"$' "${INSTALL}"
  ! grep -Eq '^[[:space:]]*(\.|source)[[:space:]]' "${INSTALL}"
}

@test "install.sh --dry-run prints the 0.2.0 URL, the checksum step, the unpack and the symlink" {
  sed 's/^ONEEXIT_VERSION="[^"]*"/ONEEXIT_VERSION="0.2.0"/' "${INSTALL}" >"${BATS_TEST_TMPDIR}/install-0.2.0.sh"
  run bash "${BATS_TEST_TMPDIR}/install-0.2.0.sh" --dry-run --insecure-skip-checksum
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] curl -fsSL --proto =https --tlsv1.2 -o "*"/oneexit-0.2.0.tar.gz https://github.com/kvozianov/oneexit/archive/refs/tags/v0.2.0.tar.gz"* ]]
  [[ "${output}" == *"==> Checking the SHA-256"* ]]
  [[ "${output}" == *"tar -xzf "*"/oneexit-0.2.0.tar.gz -C /usr/local/share/oneexit/0.2.0.new --strip-components 1"* ]]
  [[ "${output}" == *"mv /usr/local/share/oneexit/0.2.0.new /usr/local/share/oneexit/0.2.0"* ]]
  [[ "${output}" == *"ln -sfn /usr/local/share/oneexit/0.2.0/client/oneexit /usr/local/bin/oneexit"* ]]
  [[ "${output}" == *"sudo oneexit init --server root@YOUR_VPS"* ]]
  [ ! -s "${FAKE_CALL_LOG}" ]
}

@test "install.sh --dry-run without a checksum prints the refusal a real run would stop at" {
  pinned_copy ""
  run bash "${BATS_TEST_TMPDIR}/install.sh" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no checksum pinned for "*": refusing"* ]]
  [[ "${output}" == *"a real run would stop here"* ]]
  run bash "${BATS_TEST_TMPDIR}/install.sh" --dry-run --insecure-skip-checksum
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"refusing"* ]]
  [[ "${output}" == *"installing unverified because of --insecure-skip-checksum"* ]]
}

@test "install.sh without a checksum refuses before downloading anything" {
  pinned_copy ""
  run bash "${BATS_TEST_TMPDIR}/install.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"refusing to install an unverified download"* ]]
  [ ! -s "${FAKE_CALL_LOG}" ]
}

@test "install.sh --dry-run with the pinned checksum prints the sha256 command and the value" {
  pinned_copy
  run bash "${BATS_TEST_TMPDIR}/install.sh" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"refusing"* ]]
  if [ "$(uname -s)" = "Darwin" ]; then
    [[ "${output}" == *"[dry-run] shasum -a 256 "*"/oneexit-"*".tar.gz"* ]]
  else
    [[ "${output}" == *"[dry-run] sha256sum "*"/oneexit-"*".tar.gz"* ]]
  fi
  [[ "${output}" == *"[dry-run] expect ${SUM}"* ]]
}

@test "install.sh --version 9.9.9 changes the URL and the paths; the pinned checksum does not apply" {
  pinned_copy
  run bash "${BATS_TEST_TMPDIR}/install.sh" --version 9.9.9 --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"https://github.com/kvozianov/oneexit/archive/refs/tags/v9.9.9.tar.gz"* ]]
  [[ "${output}" == *"/usr/local/share/oneexit/9.9.9/client/oneexit /usr/local/bin/oneexit"* ]]
  [[ "${output}" != *"refs/tags/v0."* ]]
  [[ "${output}" == *"no checksum pinned for 9.9.9"* ]]
  run bash "${BATS_TEST_TMPDIR}/install.sh" --version v9.9.9 --sha256 "${SUM}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] expect ${SUM}"* ]]
}

@test "install.sh usage errors: bad --version, bad --sha256, unknown option; --help" {
  run bash "${INSTALL}" --version '../../etc' --dry-run
  [ "${status}" -eq 2 ]
  run bash "${INSTALL}" --sha256 abc --dry-run
  [ "${status}" -eq 2 ]
  run bash "${INSTALL}" --frobnicate
  [ "${status}" -eq 2 ]
  run bash "${INSTALL}" --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--insecure-skip-checksum"* ]]
}

@test "install.sh --dry-run works from bash -c (as in the README one-liner)" {
  run /bin/bash -c "$(cat "${INSTALL}")" install.sh --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ln -sfn /usr/local/share/oneexit/0.2.0/client/oneexit /usr/local/bin/oneexit"* ]]
}

@test "release-checksum.sh --dry-run prints the tag tarball URL; VERSION is required" {
  run bash "${REPO_ROOT}/scripts/release-checksum.sh" --dry-run 0.2.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"curl -fsSL --proto =https https://github.com/kvozianov/oneexit/archive/refs/tags/v0.2.0.tar.gz | "* ]]
  run bash "${REPO_ROOT}/scripts/release-checksum.sh"
  [ "${status}" -eq 2 ]
  [ ! -s "${FAKE_CALL_LOG}" ]
}
