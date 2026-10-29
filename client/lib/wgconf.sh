# shellcheck shell=bash
# oneexit client: read a wg-quick configuration (pure functions).
# The private key is never printed by anything in this file.

# _wg_conf_awk FILE: print "section<TAB>key<TAB>value" for every setting,
# with keys lower-cased, comments stripped and whitespace trimmed.
_wg_conf_awk() {
  awk '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    {
      line = $0
      sub(/#.*/, "", line)
      line = trim(line)
      if (line == "") next
      if (line ~ /^\[.*\]$/) { section = tolower(substr(line, 2, length(line) - 2)); next }
      eq = index(line, "=")
      if (eq == 0) next
      key = tolower(trim(substr(line, 1, eq - 1)))
      val = trim(substr(line, eq + 1))
      printf "%s\t%s\t%s\n", section, key, val
    }' "$1"
}

# wg_conf_value FILE KEY: first value of KEY (case-insensitive), any section.
# Refuses to print PrivateKey.
wg_conf_value() {
  local file="$1" key
  key="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  if [ "${key}" = "privatekey" ]; then
    printf 'wg_conf_value: refusing to print the private key\n' >&2
    return 2
  fi
  [ -r "${file}" ] || return 1
  _wg_conf_awk "${file}" | awk -F '\t' -v want="${key}" '$2 == want { print $3; found = 1; exit } END { exit !found }'
}

# parse_wg_conf FILE: KEY=value lines
#   ENDPOINT_HOST ENDPOINT_PORT ADDRESS DNS PEER_PUBLIC_KEY PRIVATE_KEY_PRESENT
parse_wg_conf() {
  local file="$1"
  if [ ! -r "${file}" ]; then
    printf 'parse_wg_conf: cannot read %s\n' "${file}" >&2
    return 1
  fi
  _wg_conf_awk "${file}" | awk -F '\t' '
    function nospace(s) { gsub(/[ \t]/, "", s); return s }
    $1 == "interface" && $2 == "address" && address == "" { address = nospace($3) }
    $1 == "interface" && $2 == "dns" && dns == "" { dns = nospace($3) }
    $1 == "interface" && $2 == "privatekey" && $3 != "" { privkey = "yes" }
    $1 == "peer" && $2 == "publickey" && pubkey == "" { pubkey = $3 }
    $1 == "peer" && $2 == "endpoint" && endpoint == "" { endpoint = $3 }
    END {
      host = endpoint; port = ""
      if (endpoint ~ /^\[/) {
        close_br = index(endpoint, "]")
        host = substr(endpoint, 2, close_br - 2)
        rest = substr(endpoint, close_br + 1)
        if (rest ~ /^:/) port = substr(rest, 2)
      } else if (endpoint ~ /:[0-9]+$/) {
        n = split(endpoint, parts, ":")
        port = parts[n]
        host = substr(endpoint, 1, length(endpoint) - length(port) - 1)
      }
      printf "ENDPOINT_HOST=%s\n", host
      printf "ENDPOINT_PORT=%s\n", port
      printf "ADDRESS=%s\n", address
      printf "DNS=%s\n", dns
      printf "PEER_PUBLIC_KEY=%s\n", pubkey
      printf "PRIVATE_KEY_PRESENT=%s\n", (privkey == "yes" ? "yes" : "no")
    }'
}

# parsed_value "PARSED_OUTPUT" KEY: pick one KEY=value line from parse_wg_conf.
parsed_value() {
  printf '%s\n' "$1" | awk -v want="$2" '
    { eq = index($0, "="); if (substr($0, 1, eq - 1) == want) { print substr($0, eq + 1); exit } }'
}

# resolve_host HOST: print one IPv4 address for HOST. IPv4 literals pass through.
resolve_host() {
  local host="$1" ip=""
  if [ -z "${host}" ]; then
    return 1
  fi
  if is_ipv4 "${host}"; then
    printf '%s\n' "${host}"
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    ip="$(dig +short +time=5 +tries=2 A "${host}" 2>/dev/null |
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)" || ip=""
  fi
  if [ -z "${ip}" ] && command -v host >/dev/null 2>&1; then
    ip="$(host -t A "${host}" 2>/dev/null |
      awk '/has address/ { print $NF; exit }')" || ip=""
  fi
  if [ -z "${ip}" ] && command -v dscacheutil >/dev/null 2>&1; then
    ip="$(dscacheutil -q host -a name "${host}" 2>/dev/null |
      awk '$1 == "ip_address:" { print $2; exit }')" || ip=""
  fi
  if [ -n "${ip}" ] && is_ipv4 "${ip}"; then
    printf '%s\n' "${ip}"
    return 0
  fi
  return 1
}
