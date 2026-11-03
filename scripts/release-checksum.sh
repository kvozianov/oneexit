#!/usr/bin/env bash
# Print the SHA-256 of the GitHub tag tarball of a oneexit release, for the
# ONEEXIT_SHA256 line of the root install.sh. Run it after pushing the tag:
#
#   scripts/release-checksum.sh 0.2.0
set -euo pipefail

REPO_URL="https://github.com/kvozianov/oneexit"

usage() {
  cat <<USAGE
Usage: scripts/release-checksum.sh [--dry-run] VERSION

Downloads ${REPO_URL}/archive/refs/tags/vVERSION.tar.gz and
prints its SHA-256 and the two lines to paste into install.sh.
--dry-run prints the commands instead. Exit codes: 0 ok, 1 failure, 2 usage.
USAGE
}

dry_run=0
version=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      printf 'error: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      [ -z "${version}" ] || {
        printf 'error: one VERSION only\n' >&2
        exit 2
      }
      version="${1#v}"
      ;;
  esac
  shift
done
case "${version}" in
  [0-9]*) ;;
  *)
    usage >&2
    exit 2
    ;;
esac
case "${version}" in
  *[!A-Za-z0-9.-]*)
    printf 'error: invalid version: %s\n' "${version}" >&2
    exit 2
    ;;
  *) ;;
esac

if [ "$(uname -s)" = "Darwin" ] && command -v shasum >/dev/null 2>&1; then
  sum=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then
  sum=(sha256sum)
else
  sum=(shasum -a 256)
fi
url="${REPO_URL}/archive/refs/tags/v${version}.tar.gz"

if [ "${dry_run}" -eq 1 ]; then
  printf '[dry-run] curl -fsSL --proto =https %s | %s\n' "${url}" "${sum[*]}"
  exit 0
fi

hash="$(curl -fsSL --proto '=https' "${url}" | "${sum[@]}" | awk '{ print $1 }')" ||
  {
    printf 'error: cannot download %s\n' "${url}" >&2
    exit 1
  }
case "${hash}" in
  *[!0-9a-f]* | '')
    printf 'error: no checksum for %s\n' "${url}" >&2
    exit 1
    ;;
  *) ;;
esac
printf '%s\n\n' "${hash}"
printf 'Paste into install.sh:\n  ONEEXIT_VERSION="%s"\n  ONEEXIT_SHA256="%s"\n' "${version}" "${hash}"
