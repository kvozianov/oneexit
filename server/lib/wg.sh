#!/usr/bin/env bash
# WireGuard helpers for the oneexit server. Rendering and parsing functions are
# pure: they take arguments (or stdin), print to stdout and touch no files.

WG_SUBNET="10.66.0.0/24"
WG_SERVER_IP="10.66.0.1"
WG_PEER_PREFIX="10.66.0."
WG_PEER_MARKER="# peers below are managed by peer.sh"

# render_server_conf PORT SERVER_PRIVKEY
render_server_conf() {
  local port="$1" privkey="$2"
  cat <<CONF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${port}
PrivateKey = ${privkey}
SaveConfig = false

${WG_PEER_MARKER}
CONF
}

# render_peer_section NAME PEER_PUBKEY PEER_IP
render_peer_section() {
  local name="$1" pubkey="$2" ip="$3"
  cat <<CONF
[Peer]
# name: ${name}
PublicKey = ${pubkey}
AllowedIPs = ${ip}/32
CONF
}

# render_peer_conf PEER_PRIVKEY PEER_IP SERVER_PUBKEY ENDPOINT PORT
# The wg-quick client config. IPv6 is intentionally absent in v1.
render_peer_conf() {
  local privkey="$1" ip="$2" server_pubkey="$3" endpoint="$4" port="$5"
  cat <<CONF
[Interface]
PrivateKey = ${privkey}
Address = ${ip}/32
DNS = ${WG_SERVER_IP}

[Peer]
PublicKey = ${server_pubkey}
Endpoint = ${endpoint}:${port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
}

# next_peer_ip WG0_CONF_PATH: lowest free 10.66.0.N (N = 2..254) not used in
# any AllowedIPs line. A missing file counts as empty. Returns 1 when full.
next_peer_ip() {
  local conf="$1" used n
  used=" "
  if [[ -r "${conf}" ]]; then
    used+="$(awk '
      /^[ \t]*AllowedIPs[ \t]*=/ {
        sub(/^[^=]*=/, "")
        n = split($0, parts, ",")
        for (i = 1; i <= n; i++) {
          ip = parts[i]
          gsub(/[ \t\r]/, "", ip)
          sub(/\/32$/, "", ip)
          if (ip ~ /^10\.66\.0\.[0-9]+$/) { sub(/^10\.66\.0\./, "", ip); printf "%d ", ip }
        }
      }' "${conf}")"
  fi
  for ((n = 2; n <= 254; n++)); do
    if [[ "${used}" != *" ${n} "* ]]; then
      printf '%s%d\n' "${WG_PEER_PREFIX}" "${n}"
      return 0
    fi
  done
  printf 'error: no free address left in %s\n' "${WG_SUBNET}" >&2
  return 1
}

# remove_peer_section NAME: read a wg0.conf on stdin, print it without the
# [Peer] block that carries "# name: NAME". Trailing blank lines are trimmed.
remove_peer_section() {
  awk -v target="# name: $1" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function flush() { if (!drop) out = out buf; buf = ""; drop = 0; is_peer = 0 }
    /^[ \t]*\[/ {
      flush()
      is_peer = (trim($0) == "[Peer]")
    }
    {
      if (is_peer && trim($0) == target) drop = 1
      buf = buf $0 "\n"
    }
    END {
      flush()
      sub(/\n+$/, "\n", out)
      printf "%s", out
    }'
}

# list_peers WG0_CONF_PATH: print "NAME<TAB>IP<TAB>PUBKEY" for every [Peer]
# block (NAME is "-" when the block has no "# name:" comment).
list_peers() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function flush() {
      if (is_peer) printf "%s\t%s\t%s\n", (name == "" ? "-" : name), (ip == "" ? "-" : ip), (pub == "" ? "-" : pub)
      is_peer = 0; name = ""; ip = ""; pub = ""
    }
    /^[ \t]*\[/ { flush(); is_peer = (trim($0) == "[Peer]"); next }
    is_peer && /^[ \t]*#[ \t]*name:/ { line = $0; sub(/^[ \t]*#[ \t]*name:/, "", line); name = trim(line); next }
    is_peer && /^[ \t]*PublicKey[ \t]*=/ { line = $0; sub(/^[^=]*=/, "", line); pub = trim(line); next }
    is_peer && /^[ \t]*AllowedIPs[ \t]*=/ { line = $0; sub(/^[^=]*=/, "", line); ip = trim(line); sub(/\/32$/, "", ip); next }
    END { flush() }' "$1"
}

# peer_pubkey_from_conf WG0_CONF_PATH NAME: PublicKey of the named peer.
peer_pubkey_from_conf() {
  local conf="$1" name="$2" n ip pub
  while IFS=$'\t' read -r n ip pub; do
    if [[ "${n}" == "${name}" ]]; then
      printf '%s\n' "${pub}"
      return 0
    fi
  done < <(list_peers "${conf}")
  return 1
}

# gen_keys: generate a key pair into WG_PRIVKEY and WG_PUBKEY (globals, so the
# placeholder counter survives between calls). In dry-run, or when `wg` is not
# installed, deterministic placeholders DRYRUN_PRIVATE_KEY_<n> /
# DRYRUN_PUBLIC_KEY_<n> are used instead; the installer and peer.sh require
# `wg` outside dry-run, so placeholders never reach a real config.
_GEN_KEYS_COUNT=0
gen_keys() {
  if [[ "${DRY_RUN:-0}" == "1" ]] || ! command -v wg >/dev/null 2>&1; then
    _GEN_KEYS_COUNT=$((_GEN_KEYS_COUNT + 1))
    # shellcheck disable=SC2034  # consumed by the caller
    WG_PRIVKEY="DRYRUN_PRIVATE_KEY_${_GEN_KEYS_COUNT}"
    # shellcheck disable=SC2034  # consumed by the caller
    WG_PUBKEY="DRYRUN_PUBLIC_KEY_${_GEN_KEYS_COUNT}"
    return 0
  fi
  WG_PRIVKEY="$(wg genkey)"
  # shellcheck disable=SC2034  # consumed by the caller
  WG_PUBKEY="$(printf '%s\n' "${WG_PRIVKEY}" | wg pubkey)"
}
