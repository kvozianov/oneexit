#!/usr/bin/env bash
# oneexit bootstrap for the Mac: downloads one pinned release of oneexit,
# checks its SHA-256, unpacks it to /usr/local/share/oneexit/<version> and
# links /usr/local/bin/oneexit. It never runs "oneexit init" itself.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kvozianov/oneexit/main/install.sh)"
#
# Self-contained on purpose (nothing is sourced): this file is all that runs
# before the checksum is verified. Read it first if you like; it is short.
set -euo pipefail

# Filled in by the release step (scripts/release-checksum.sh VERSION prints
# the checksum of the GitHub tag tarball): the version this script installs
# and the SHA-256 of https://github.com/kvozianov/oneexit/archive/refs/tags/v<version>.tar.gz
ONEEXIT_VERSION="0.2.1"
ONEEXIT_SHA256="f6ebc41bc1a7dced489b904edb7863a06059cc7c6fd84d08f5d4ea4a15c7de2d"

REPO_URL="https://github.com/kvozianov/oneexit"
SHARE_DIR="/usr/local/share/oneexit"
BIN_LINK="/usr/local/bin/oneexit"

DRY_RUN=0
SKIP_CHECKSUM=0
VERSION="${ONEEXIT_VERSION}"
SHA256=""

usage() {
  cat <<USAGE
Usage: install.sh [--version X] [--sha256 HEX] [--insecure-skip-checksum] [--dry-run]

Installs the oneexit command on this Mac:
  1. downloads ${REPO_URL}/archive/refs/tags/vVERSION.tar.gz
  2. checks its SHA-256 against the value pinned in this script
  3. unpacks it to ${SHARE_DIR}/VERSION (needs sudo)
  4. links ${BIN_LINK} to that copy's client/oneexit
Then run: sudo oneexit init --server root@YOUR_VPS

Options:
  --version X               install release X instead of ${ONEEXIT_VERSION}
  --sha256 HEX              expected SHA-256 of that release's tarball (the
                            pinned value only applies to ${ONEEXIT_VERSION})
  --insecure-skip-checksum  install without a checksum (not recommended)
  --dry-run                 print what would be downloaded, checked and
                            written; no network, no sudo, nothing changed
  -h, --help                show this help

Exit codes: 0 ok, 1 failure, 2 usage error.
USAGE
}

say() { printf '==> %s\n' "$*"; }
ok() { printf 'ok: %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
usage_error() {
  printf 'error: %s\n' "$*" >&2
  printf 'See: install.sh --help\n' >&2
  exit 2
}

# Quote one word so that a printed command can be pasted back.
quote() {
  case "$1" in
    '') printf "''" ;;
    *[!A-Za-z0-9_./:=@%+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

show() {
  local out="" word
  for word in "$@"; do
    out="${out}${out:+ }$(quote "${word}")"
  done
  printf '%s' "${out}"
}

# run CMD...: execute, or print it in a dry run.
run() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '[dry-run] %s\n' "$(show "$@")"
    return 0
  fi
  "$@"
}

# as_root CMD...: run CMD as root (through sudo unless already root).
SUDO=""
as_root() {
  if [ -n "${SUDO}" ]; then
    run "${SUDO}" "$@"
  else
    run "$@"
  fi
}

# sha256_tool: the SHA-256 command of this OS (shasum on macOS, sha256sum on Linux).
sha256_tool() {
  if [ "$(uname -s)" = "Darwin" ] && command -v shasum >/dev/null 2>&1; then
    echo "shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    echo "shasum -a 256"
  else
    return 1
  fi
}

valid_version() {
  case "$1" in
    '' | -* | *[!A-Za-z0-9.-]*) return 1 ;;
    [0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_sha256() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
    *) [ "${#1}" -eq 64 ] ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || usage_error "--version needs a value"
      VERSION="$2"
      shift
      ;;
    --version=*) VERSION="${1#--version=}" ;;
    --sha256)
      [ "$#" -ge 2 ] || usage_error "--sha256 needs a value"
      SHA256="$2"
      shift
      ;;
    --sha256=*) SHA256="${1#--sha256=}" ;;
    --insecure-skip-checksum) SKIP_CHECKSUM=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

VERSION="${VERSION#v}"
valid_version "${VERSION}" || usage_error "invalid --version: ${VERSION} (for example ${ONEEXIT_VERSION})"
SHA256="$(printf '%s' "${SHA256}" | tr '[:upper:]' '[:lower:]')"
if [ -n "${SHA256}" ] && ! valid_sha256 "${SHA256}"; then
  usage_error "invalid --sha256: 64 hex digits expected"
fi
# The pinned checksum belongs to the pinned version only.
if [ -z "${SHA256}" ] && [ "${VERSION}" = "${ONEEXIT_VERSION}" ]; then
  SHA256="${ONEEXIT_SHA256}"
fi

URL="${REPO_URL}/archive/refs/tags/v${VERSION}.tar.gz"
DEST="${SHARE_DIR}/${VERSION}"

if [ "${DRY_RUN}" -eq 1 ]; then
  printf 'Dry run: no download, no sudo, nothing changed. Commands are printed below.\n'
fi

if [ "$(id -u)" -ne 0 ]; then
  # Root is needed for /usr/local only. Download and check as this user,
  # then use sudo for the few commands that write there (this also works
  # when the script comes from bash -c, where there is no file to re-run).
  SUDO="sudo"
fi

say "oneexit ${VERSION}"
command -v curl >/dev/null 2>&1 || [ "${DRY_RUN}" -eq 1 ] || die "curl not found"
command -v tar >/dev/null 2>&1 || [ "${DRY_RUN}" -eq 1 ] || die "tar not found"
SUM_TOOL="$(sha256_tool)" || SUM_TOOL=""
[ -n "${SUM_TOOL}" ] || [ "${DRY_RUN}" -eq 1 ] || [ "${SKIP_CHECKSUM}" -eq 1 ] ||
  die "neither shasum nor sha256sum found"

# ---------------------------------------------------------------- checksum policy

# Decided before anything is downloaded: no pinned checksum, no install.
if [ -z "${SHA256}" ] && [ "${SKIP_CHECKSUM}" -eq 0 ]; then
  msg="no checksum pinned for ${VERSION}: refusing to install an unverified download (pass --sha256 HEX, or --insecure-skip-checksum, or use the git clone install from the README)"
  if [ "${DRY_RUN}" -eq 1 ]; then
    warn "${msg}"
    warn "a real run would stop here; the dry run goes on to show the rest"
  else
    die "${msg}"
  fi
fi

# ---------------------------------------------------------------- download

if [ "${DRY_RUN}" -eq 1 ]; then
  TMP_DIR="${TMPDIR:-/tmp}"
  TMP_DIR="${TMP_DIR%/}/oneexit-install.XXXXXX"
else
  TMP_DIR="${TMPDIR:-/tmp}"
  TMP_DIR="$(mktemp -d "${TMP_DIR%/}/oneexit-install.XXXXXX")"
  trap 'rm -rf "${TMP_DIR}"' EXIT
fi
TARBALL="${TMP_DIR}/oneexit-${VERSION}.tar.gz"

say "Downloading ${URL}"
run curl -fsSL --proto '=https' --tlsv1.2 -o "${TARBALL}" "${URL}" ||
  die "download failed: ${URL} (is ${VERSION} a released version? see ${REPO_URL}/releases)"

# ---------------------------------------------------------------- checksum

say "Checking the SHA-256"
if [ -n "${SHA256}" ]; then
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '[dry-run] %s %s\n' "${SUM_TOOL:-sha256sum}" "$(quote "${TARBALL}")"
    printf '[dry-run] expect %s\n' "${SHA256}"
  else
    # shellcheck disable=SC2086 # SUM_TOOL is "shasum -a 256" or "sha256sum"
    actual="$(${SUM_TOOL} "${TARBALL}" | awk '{ print $1 }')"
    if [ "${actual}" != "${SHA256}" ]; then
      die "checksum mismatch for ${URL}: expected ${SHA256}, got ${actual}. Nothing was installed."
    fi
    ok "sha256 ${actual}"
  fi
elif [ "${SKIP_CHECKSUM}" -eq 1 ]; then
  warn "no checksum for ${VERSION}: installing unverified because of --insecure-skip-checksum"
else
  warn "no checksum for ${VERSION}: not verified (dry run)"
fi

# ---------------------------------------------------------------- unpack and link

say "Unpacking to ${DEST}"
as_root mkdir -p "${SHARE_DIR}"
as_root rm -rf "${DEST}.new"
as_root mkdir -p "${DEST}.new"
# GitHub tarballs have one top directory (oneexit-VERSION/).
as_root tar -xzf "${TARBALL}" -C "${DEST}.new" --strip-components 1 --no-same-owner
if [ "${DRY_RUN}" -eq 0 ] && [ ! -f "${DEST}.new/client/oneexit" ]; then
  as_root rm -rf "${DEST}.new"
  die "${URL} does not contain client/oneexit; nothing was installed"
fi
as_root chown -R 0:0 "${DEST}.new"
as_root rm -rf "${DEST}"
as_root mv "${DEST}.new" "${DEST}"
ok "${DEST}"

say "Linking ${BIN_LINK}"
as_root mkdir -p "$(dirname "${BIN_LINK}")"
as_root ln -sfn "${DEST}/client/oneexit" "${BIN_LINK}"
ok "${BIN_LINK} -> ${DEST}/client/oneexit"

cat <<NEXT

oneexit ${VERSION} is installed. Next step (needs a VPS with ssh key login):

  sudo oneexit init --server root@YOUR_VPS

Preview everything it would do first: oneexit init --server root@YOUR_VPS --dry-run
NEXT
if [ "${DRY_RUN}" -eq 1 ]; then
  printf '(dry run: nothing was changed)\n'
fi
