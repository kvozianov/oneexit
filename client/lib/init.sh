# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# oneexit client: "oneexit init", the one-command setup. From the Mac it
# installs the server over ssh, fetches the peer config, runs the client
# setup and the hardening, and checks the result. Needs common.sh, pf.sh,
# wgconf.sh, privacy.sh and setup_steps.sh. Stock bash 3.2 compatible.
#
# Layout: pure functions (target parsing, command builders), then the six
# steps (init_step1 .. init_step6), then init_main. Every remote command goes
# through ssh_argv/ssh_cmd, so --dry-run prints exactly what would run and
# never calls ssh, tar or the network.

INIT_STEPS=6
INIT_DEFAULT_WG_PORT=51820
INIT_DEFAULT_PEER="mac"
INIT_REMOTE_DIR="/opt/oneexit"
INIT_HANDSHAKE_WAIT="${INIT_HANDSHAKE_WAIT:-30}"
INIT_SSH_CONNECT_TIMEOUT=10
# Stand-in address for a hostname in --dry-run (TEST-NET-1, RFC 5737): a dry
# run does not resolve names, because that would be network access.
INIT_DRY_RUN_IP="192.0.2.1"

INIT_SERVER=""
INIT_USER=""
INIT_HOST=""
INIT_SSH_PORT=""
INIT_SSH_KEY=""
INIT_WG_PORT=""
INIT_PEER=""
INIT_CONFIG=""
INIT_INTERACTIVE=0
INIT_TZ_GIVEN=0
INIT_REGION_GIVEN=0
HOST_IP=""
INIT_TMP_PEER=""
SSH_ARGV=()

init_usage() {
  cat <<USAGE
Usage: sudo oneexit init --server [USER@]HOST[:SSHPORT] [options]
       sudo oneexit init                      (asks for the server address)
       sudo oneexit init --config PEER.conf   (server installed by hand)

Sets up everything from this Mac in six steps:
  1. pre-flight checks (external boot disk, Homebrew, ssh, the address)
  2. ssh login to the server (key-based; a non-root login needs sudo -n)
  3. uploads server/ to ${INIT_REMOTE_DIR}, runs server/install.sh there and
     fetches the peer config
  4. client setup (as client/setup.sh: kill switch, tunnel, DNS, IPv6 off)
  5. hardening (as oneexit harden: Location Services, time zone, region,
     computer name, WebRTC)
  6. waits for the tunnel and runs the leak test against the server's IP

Options:
  --server [USER@]HOST[:SSHPORT]
                          the VPS: a fresh Debian 12+ / Ubuntu 22.04+ with ssh
                          key login (user default root, ssh port default 22)
  --ssh-key PATH          private key for the ssh login (default: ssh's own)
  --port N                WireGuard UDP port on the server (default ${INIT_DEFAULT_WG_PORT};
                          443 helps on restrictive networks)
  --peer NAME             name of this Mac on the server (default ${INIT_DEFAULT_PEER})
  --timezone TZ           time zone of the exit country (default: the server's
                          own zone unless it is UTC, else ${PRIVACY_DEFAULT_TIMEZONE})
  --region RR             two-letter region (default: the country of the time
                          zone, else ${PRIVACY_DEFAULT_REGION})
  --config PATH           skip steps 2 and 3: use a peer config made by
                          server/peer.sh (its "# oneexit-timezone" line is the
                          default time zone)
  --no-harden             skip step 5 (sudo oneexit harden later)
  --allow-internal-disk   install even though macOS runs from the internal disk
  --dry-run               print every ssh, tar and setup command; no network,
                          nothing changed
  --help                  show this help

ssh runs as the user who called sudo, with that user's keys, agent and
known_hosts; a server seen for the first time is added to known_hosts.
Exit codes: 0 ok, 1 failure (or a failed leak test), 2 usage error.
USAGE
}

# ---------------------------------------------------------------- pure functions

# is_hostname NAME: a DNS name (labels of letters, digits and "-", no label
# starting or ending with "-"). All-numeric names must be valid IPv4.
is_hostname() {
  local name="$1" label rest
  case "${name}" in
    '' | .* | *. | *..* | *[!A-Za-z0-9.-]*) return 1 ;;
    *[!0-9.]*) ;;
    *) return 1 ;;
  esac
  [ "${#name}" -le 253 ] || return 1
  rest="${name}"
  while [ -n "${rest}" ]; do
    label="${rest%%.*}"
    case "${rest}" in
      *.*) rest="${rest#*.}" ;;
      *) rest="" ;;
    esac
    [ -n "${label}" ] && [ "${#label}" -le 63 ] || return 1
    case "${label}" in
      -* | *-) return 1 ;;
      *) ;;
    esac
  done
  return 0
}

# is_ssh_user NAME: a POSIX-ish login name.
is_ssh_user() {
  case "$1" in
    '' | -* | *[!A-Za-z0-9._-]*) return 1 ;;
    *) [ "${#1}" -le 32 ] ;;
  esac
}

# parse_server_target "[user@]host[:port]": prints USER=, HOST= and PORT=
# lines (defaults root and 22). Returns 2 (with a message on stderr) for
# anything else: IPv6, empty parts, bad characters, a bad port.
parse_server_target() {
  local target="$1" user="root" host port="22"
  case "${target}" in
    '' | *[[:space:]]* | *'['* | *']'*)
      printf 'error: invalid server address "%s" (expected [user@]host[:port])\n' "${target}" >&2
      return 2
      ;;
    *@*@*)
      printf 'error: invalid server address "%s" (more than one "@")\n' "${target}" >&2
      return 2
      ;;
    *@*)
      user="${target%%@*}"
      host="${target#*@}"
      ;;
    *) host="${target}" ;;
  esac
  case "${host}" in
    *:*:*)
      printf 'error: invalid server address "%s" (IPv6 is not supported; use the IPv4 address or a hostname)\n' "${target}" >&2
      return 2
      ;;
    *:*)
      port="${host##*:}"
      host="${host%:*}"
      ;;
    *) ;;
  esac
  if ! is_ssh_user "${user}"; then
    printf 'error: invalid user in "%s"\n' "${target}" >&2
    return 2
  fi
  if ! is_ipv4 "${host}" && ! is_hostname "${host}"; then
    printf 'error: invalid host in "%s" (an IPv4 address or a hostname)\n' "${target}" >&2
    return 2
  fi
  if ! is_port "${port}"; then
    printf 'error: invalid ssh port in "%s" (1-65535)\n' "${target}" >&2
    return 2
  fi
  printf 'USER=%s\nHOST=%s\nPORT=%s\n' "${user}" "${host}" "${port}"
}

# init_set_target TARGET: parse_server_target into INIT_USER, INIT_HOST,
# INIT_SSH_PORT. Returns 2 on a bad address.
init_set_target() {
  local parsed
  parsed="$(parse_server_target "$1")" || return 2
  INIT_SERVER="$1"
  INIT_USER="$(printf '%s\n' "${parsed}" | sed -n 's/^USER=//p')"
  INIT_HOST="$(printf '%s\n' "${parsed}" | sed -n 's/^HOST=//p')"
  INIT_SSH_PORT="$(printf '%s\n' "${parsed}" | sed -n 's/^PORT=//p')"
}

# remote_sudo_prefix USER: "sudo -n" for a non-root login, nothing for root.
remote_sudo_prefix() {
  if [ "$1" != "root" ]; then
    printf 'sudo -n\n'
  fi
}

# _remote CMD...: CMD as one remote shell string, with the sudo prefix.
_remote() {
  local prefix
  prefix="$(remote_sudo_prefix "${INIT_USER}")"
  printf '%s%s%s\n' "${prefix}" "${prefix:+ }" "$(quote_cmd "$@")"
}

# init_ssh_agent_sock: the agent socket of the user who called sudo (sudo
# drops SSH_AUTH_SOCK; launchd still knows it), or nothing.
init_ssh_agent_sock() {
  local uid
  if [ -n "${ONEEXIT_SSH_AUTH_SOCK:-}" ]; then
    printf '%s\n' "${ONEEXIT_SSH_AUTH_SOCK}"
  elif [ -n "${SSH_AUTH_SOCK:-}" ]; then
    printf '%s\n' "${SSH_AUTH_SOCK}"
  elif is_root && [ -n "${SUDO_USER:-}" ] && command -v launchctl >/dev/null 2>&1; then
    uid="$(id -u "${SUDO_USER}" 2>/dev/null || true)"
    if is_uint "${uid}"; then
      launchctl asuser "${uid}" launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true
    fi
  fi
}

# ssh_argv [REMOTE_COMMAND]: fill SSH_ARGV with the ssh command line for the
# server: batch mode (no password prompts), a connect timeout, first-seen
# host keys accepted (changed ones refused), --ssh-key and the ssh port.
ssh_argv() {
  SSH_ARGV=(ssh -o BatchMode=yes -o "ConnectTimeout=${INIT_SSH_CONNECT_TIMEOUT}" -o StrictHostKeyChecking=accept-new)
  if [ -n "${INIT_SSH_KEY}" ]; then
    SSH_ARGV+=(-o IdentitiesOnly=yes -i "${INIT_SSH_KEY}")
  fi
  if [ -n "${INIT_SSH_PORT}" ] && [ "${INIT_SSH_PORT}" != "22" ]; then
    SSH_ARGV+=(-p "${INIT_SSH_PORT}")
  fi
  SSH_ARGV+=("${INIT_USER}@${INIT_HOST}")
  if [ "$#" -gt 0 ]; then
    SSH_ARGV+=("$1")
  fi
}

# ssh_cmd [REMOTE_COMMAND]: the ssh command line, quoted so it can be pasted.
ssh_cmd() {
  ssh_argv "$@"
  quote_cmd "${SSH_ARGV[@]}"
}

# _as_login_user CMD...: run CMD as the user who called sudo (their ssh keys,
# agent and known_hosts), or as is when not running through sudo.
_as_login_user() {
  local sock
  if is_root && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    sock="$(init_ssh_agent_sock)"
    sudo -u "${SUDO_USER}" -H env ${sock:+"SSH_AUTH_SOCK=${sock}"} "$@"
  else
    "$@"
  fi
}

# init_ssh REMOTE_COMMAND: run it on the server (stdin from /dev/null).
init_ssh() {
  ssh_argv "$1"
  _as_login_user "${SSH_ARGV[@]}" </dev/null
}

# init_upload_remote: the remote half of the upload. The directory is removed
# and re-created with mkdir (no -p, mode 0700), so a ${INIT_REMOTE_DIR} that
# someone else created in /tmp makes the upload fail instead of being used.
init_upload_remote() {
  local prefix
  prefix="$(remote_sudo_prefix "${INIT_USER}")"
  prefix="${prefix}${prefix:+ }"
  printf '%srm -rf %s && %smkdir -m 0700 %s && %star -C %s --no-same-owner -xf -\n' \
    "${prefix}" "${INIT_REMOTE_DIR}" "${prefix}" "${INIT_REMOTE_DIR}" "${prefix}" "${INIT_REMOTE_DIR}"
}

# init_upload_local: the local half (ustar: no macOS extended attributes).
init_upload_local() {
  printf 'COPYFILE_DISABLE=1 %s\n' "$(quote_cmd tar --format ustar -C "${REPO_DIR}" -cf - server)"
}

# init_install_remote: server/install.sh with the endpoint the Mac resolved.
# --quiet-peer: no peer config or QR code in the streamed output (init_cat_remote
# fetches the config) and no manual scp/setup steps.
init_install_remote() {
  _remote bash "${INIT_REMOTE_DIR}/server/install.sh" --endpoint "${HOST_IP}" \
    --port "${INIT_WG_PORT}" --peer "${INIT_PEER}" --timezone "${TIMEZONE}" --quiet-peer
}

init_cat_remote() {
  _remote cat "/etc/wireguard/peers/${INIT_PEER}.conf"
}

init_tz_remote() {
  _remote timedatectl show -p Timezone --value
}

# init_tz_is_utc TZ: the names that mean "no zone was chosen".
init_tz_is_utc() {
  case "$1" in
    '' | UTC | UCT | Etc/UTC | Etc/UCT | Universal | Etc/Universal | Zulu | Etc/Zulu | \
      GMT | GMT0 | Etc/GMT | Etc/GMT0 | Etc/GMT+0 | Etc/GMT-0 | Greenwich | Etc/Greenwich) return 0 ;;
    *) return 1 ;;
  esac
}

# init_default_timezone SERVER_TZ: the server's zone unless it is UTC (or
# unknown on this Mac), else the default.
init_default_timezone() {
  if ! init_tz_is_utc "$1" && tz_is_valid "$1"; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "${PRIVACY_DEFAULT_TIMEZONE}"
  fi
}

# init_default_region TZ: the country of TZ, else the default.
init_default_region() {
  local r
  r="$(region_from_timezone "$1")"
  printf '%s\n' "${r:-${PRIVACY_DEFAULT_REGION}}"
}

# init_placeholder_peer_conf: the peer config a dry run pretends to fetch
# (the real one exists only after install.sh ran on the server).
init_placeholder_peer_conf() {
  cat <<CONF
# oneexit-timezone = ${TIMEZONE}
[Interface]
PrivateKey = DRYRUNplaceholderPRIVATEkeyDRYRUNplaceholder0=
Address = 10.66.0.2/32
DNS = 10.66.0.1

[Peer]
PublicKey = DRYRUNplaceholderSERVERkeyDRYRUNplaceholder00=
Endpoint = ${HOST_IP}:${INIT_WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
}

# ---------------------------------------------------------------- arguments

init_parse_args() {
  INIT_WG_PORT="${INIT_DEFAULT_WG_PORT}"
  INIT_PEER="${INIT_DEFAULT_PEER}"
  local server=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --server)
        [ "$#" -ge 2 ] || usage_error "--server needs [user@]host[:port]"
        server="$2"
        shift
        ;;
      --server=*) server="${1#--server=}" ;;
      --ssh-key)
        [ "$#" -ge 2 ] || usage_error "--ssh-key needs a path"
        INIT_SSH_KEY="$2"
        shift
        ;;
      --ssh-key=*) INIT_SSH_KEY="${1#--ssh-key=}" ;;
      --port)
        [ "$#" -ge 2 ] || usage_error "--port needs a value"
        INIT_WG_PORT="$2"
        shift
        ;;
      --port=*) INIT_WG_PORT="${1#--port=}" ;;
      --peer)
        [ "$#" -ge 2 ] || usage_error "--peer needs a name"
        INIT_PEER="$2"
        shift
        ;;
      --peer=*) INIT_PEER="${1#--peer=}" ;;
      --timezone)
        [ "$#" -ge 2 ] || usage_error "--timezone needs a value"
        TIMEZONE="$2"
        shift
        ;;
      --timezone=*) TIMEZONE="${1#--timezone=}" ;;
      --region)
        [ "$#" -ge 2 ] || usage_error "--region needs a value"
        REGION="$2"
        shift
        ;;
      --region=*) REGION="${1#--region=}" ;;
      --config)
        [ "$#" -ge 2 ] || usage_error "--config needs a path"
        INIT_CONFIG="$2"
        shift
        ;;
      --config=*) INIT_CONFIG="${1#--config=}" ;;
      --no-harden) NO_HARDEN=1 ;;
      --allow-internal-disk) ALLOW_INTERNAL=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        init_usage
        exit 0
        ;;
      *)
        log_error "unknown option: $1"
        init_usage >&2
        exit 2
        ;;
    esac
    shift
  done

  [ -n "${TIMEZONE}" ] && INIT_TZ_GIVEN=1
  [ -n "${REGION}" ] && INIT_REGION_GIVEN=1
  if [ -n "${server}" ] && [ -n "${INIT_CONFIG}" ]; then
    usage_error "--server and --config exclude each other (--config skips the server install)"
  fi
  if [ -n "${server}" ]; then
    init_set_target "${server}" || exit 2
  elif [ -z "${INIT_CONFIG}" ]; then
    if [ -t 0 ]; then
      INIT_INTERACTIVE=1
    else
      log_error "no server given: pass --server [user@]host[:port] (or --config PEER.conf)"
      init_usage >&2
      exit 2
    fi
  fi
  if [ -n "${INIT_CONFIG}" ] && [ ! -r "${INIT_CONFIG}" ]; then
    die "cannot read ${INIT_CONFIG}"
  fi
  is_port "${INIT_WG_PORT}" || usage_error "invalid --port: ${INIT_WG_PORT} (1-65535)"
  case "${INIT_PEER}" in
    '' | -* | *[!A-Za-z0-9_-]*) usage_error "invalid --peer: ${INIT_PEER} (letters, digits, '-', '_'; max 32)" ;;
    *) [ "${#INIT_PEER}" -le 32 ] || usage_error "invalid --peer: ${INIT_PEER} (max 32 characters)" ;;
  esac
  if [ -n "${INIT_SSH_KEY}" ] && [ ! -r "${INIT_SSH_KEY}" ] && ! is_dry_run; then
    die "cannot read the ssh key ${INIT_SSH_KEY}"
  fi
  setup_validate_options
}

# init_ask PROMPT DEFAULT: one line from stdin, DEFAULT when empty.
init_ask() {
  local answer=""
  printf '%s [%s]: ' "$1" "$2" >&2
  IFS= read -r answer || answer=""
  printf '%s\n' "${answer:-$2}"
}

init_prompt_server() {
  local answer tries=0
  cat >&2 <<'MSG'
oneexit init sets up your VPS and this Mac in one go. You need a fresh
Debian 12+ or Ubuntu 22.04+ server that accepts your ssh key.
MSG
  while :; do
    printf 'Server address ([user@]host[:port], e.g. root@203.0.113.5): ' >&2
    IFS= read -r answer || usage_error "no server address given"
    if init_set_target "${answer}"; then
      return 0
    fi
    tries=$((tries + 1))
    [ "${tries}" -lt 3 ] || usage_error "no valid server address given"
  done
}

init_prompt_privacy() {
  local answer def
  if [ "${INIT_TZ_GIVEN}" -eq 0 ]; then
    def="${TIMEZONE}"
    while :; do
      answer="$(init_ask "Time zone of the exit country" "${def}")"
      tz_is_valid "${answer}" && break
      log_warn "unknown time zone: ${answer} (for example ${PRIVACY_DEFAULT_TIMEZONE})"
    done
    TIMEZONE="${answer}"
  fi
  if [ "${INIT_REGION_GIVEN}" -eq 0 ]; then
    def="$(init_default_region "${TIMEZONE}")"
    while :; do
      answer="$(region_normalize "$(init_ask "Region (two letters)" "${def}")")"
      region_is_valid "${answer}" && break
      log_warn "invalid region: ${answer} (two letters, for example ${PRIVACY_DEFAULT_REGION})"
    done
    REGION="${answer}"
  fi
}

# ---------------------------------------------------------------- steps

init_step_header() {
  log_step "Step $1/${INIT_STEPS}: $2"
}

# init_find_repo: REPO_DIR with server/install.sh (the checkout this CLI runs
# from, ONEEXIT_REPO_DIR, or the release unpacked by the bootstrap install.sh).
init_find_repo() {
  local cand
  for cand in "${ONEEXIT_REPO_DIR:-}" "${SELF_DIR}/.." "/usr/local/share/oneexit/${ONEEXIT_VERSION}"; do
    if [ -n "${cand}" ] && [ -f "${cand}/server/install.sh" ] && [ -f "${cand}/client/lib/common.sh" ]; then
      REPO_DIR="$(cd -P "${cand}" && pwd)"
      SETUP_CLIENT_DIR="${REPO_DIR}/client"
      return 0
    fi
  done
  return 1
}

init_step1() {
  init_step_header 1 "Pre-flight checks"
  setup_preflight
  if [ -z "${INIT_CONFIG}" ]; then
    if command -v ssh >/dev/null 2>&1; then
      log_ok "ssh: $(command -v ssh)"
    elif is_dry_run; then
      log_warn "ssh not found; a real run would stop here"
    else
      die "ssh not found (it ships with macOS: /usr/bin/ssh)"
    fi
    log_ok "server: ${INIT_USER}@${INIT_HOST}, ssh port ${INIT_SSH_PORT}"
  fi
  log_ok "pre-flight checks passed"
}

init_ssh_failed() {
  local what="$1" cmd port_opt=""
  cmd="$(ssh_cmd true)"
  [ "${INIT_SSH_PORT}" = "22" ] || port_opt="-p ${INIT_SSH_PORT} "
  log_error "${what}"
  cat >&2 <<MSG

Try the login by hand (as your normal user, not with sudo):

  ${cmd}

Usual causes:
  * the server does not have your public key (~/.ssh/id_ed25519.pub):
    ssh-copy-id ${port_opt}${INIT_USER}@${INIT_HOST}, or paste it into the
    provider's control panel; pass another key with --ssh-key PATH
  * the server only accepts passwords (oneexit needs key login; batch mode
    never asks for a password)
  * the key has a passphrase and no ssh-agent holds it: ssh-add first
  * the provider's firewall blocks ssh port ${INIT_SSH_PORT}, or the address is wrong
  * the host key changed (a reinstalled server): remove the old line with
    ssh-keygen -R ${INIT_HOST}
MSG
  if [ -r "${ONEEXIT_CONFIG}" ]; then
    cat >&2 <<'MSG'
  * oneexit is already active on this Mac: its kill switch lets only
    WireGuard reach the server. Run "sudo oneexit unlock" first, then init.
MSG
  fi
  exit 1
}

init_step2() {
  local server_tz=""
  if [ -n "${INIT_CONFIG}" ]; then
    init_step_header 2 "Server: skipped (--config: the server was installed by hand)"
    return 0
  fi
  init_step_header 2 "Server reachability"
  if is_ipv4 "${INIT_HOST}"; then
    HOST_IP="${INIT_HOST}"
  elif is_dry_run; then
    HOST_IP="${INIT_DRY_RUN_IP}"
    log_info "[dry-run] resolve ${INIT_HOST} to its IPv4 address (${HOST_IP} stands in for it below)"
  else
    HOST_IP="$(resolve_host "${INIT_HOST}")" ||
      die "cannot resolve ${INIT_HOST} to an IPv4 address; pass --server with the server's IPv4 address"
    log_ok "${INIT_HOST} is ${HOST_IP}"
  fi

  if is_dry_run; then
    log_info "[dry-run] $(ssh_cmd true)"
    if [ -n "$(remote_sudo_prefix "${INIT_USER}")" ]; then
      log_info "[dry-run] $(ssh_cmd "sudo -n true")"
    fi
  else
    init_ssh true >/dev/null || init_ssh_failed "cannot log in to ${INIT_USER}@${INIT_HOST} with ssh."
    log_ok "ssh login as ${INIT_USER}@${INIT_HOST} works"
    if [ -n "$(remote_sudo_prefix "${INIT_USER}")" ]; then
      if ! init_ssh "sudo -n true" >/dev/null 2>&1; then
        log_error "${INIT_USER} cannot run sudo without a password on ${INIT_HOST}."
        cat >&2 <<MSG

Every server command runs as "sudo -n ..." for a login other than root.
Log in as root (--server root@${INIT_HOST}), or allow passwordless sudo for
${INIT_USER} on the server (a line "${INIT_USER} ALL=(ALL) NOPASSWD:ALL" in
/etc/sudoers.d/${INIT_USER}).
MSG
        exit 1
      fi
      log_ok "${INIT_USER} may use sudo -n on the server"
    fi
  fi

  if [ "${INIT_TZ_GIVEN}" -eq 0 ]; then
    if is_dry_run; then
      log_info "[dry-run] $(ssh_cmd "$(init_tz_remote)")"
      TIMEZONE="${PRIVACY_DEFAULT_TIMEZONE}"
      log_info "    (dry run: the server's zone is not known; ${TIMEZONE} stands in for it)"
    else
      server_tz="$(init_ssh "$(init_tz_remote)" 2>/dev/null | head -n 1 | tr -d '[:space:]')" || server_tz=""
      TIMEZONE="$(init_default_timezone "${server_tz}")"
      if [ "${TIMEZONE}" = "${server_tz}" ]; then
        log_ok "time zone ${TIMEZONE} (the server's own)"
      else
        log_ok "time zone ${TIMEZONE} (the server reports ${server_tz:-nothing}; using the default)"
      fi
    fi
  fi
  if [ "${INIT_INTERACTIVE}" -eq 1 ]; then
    init_prompt_privacy
  fi
  if [ -z "${REGION}" ]; then
    REGION="$(init_default_region "${TIMEZONE}")"
  fi
  log_ok "exit time zone ${TIMEZONE}, region ${REGION}"
}

init_cleanup() {
  if [ -n "${INIT_TMP_PEER}" ]; then
    rm -f "${INIT_TMP_PEER}"
  fi
}

init_new_tmp_peer() {
  local tmp="${TMPDIR:-/tmp}"
  INIT_TMP_PEER="$(umask 077 && mktemp "${tmp%/}/oneexit-peer.XXXXXX")" ||
    die "cannot create a temporary file"
  trap init_cleanup EXIT
  chmod 0600 "${INIT_TMP_PEER}"
}

init_step3() {
  local remote_upload
  if [ -n "${INIT_CONFIG}" ]; then
    init_step_header 3 "Server install: skipped (--config)"
    PEER_CONF="${INIT_CONFIG}"
    return 0
  fi
  init_step_header 3 "Installing the server on ${INIT_HOST}"
  remote_upload="$(init_upload_remote)"
  if is_dry_run; then
    log_info "[dry-run] $(init_upload_local) | $(ssh_cmd "${remote_upload}")"
    log_info "[dry-run] $(ssh_cmd "$(init_install_remote)") >&2"
    log_info "[dry-run] $(ssh_cmd "$(init_cat_remote)") > (temporary file, mode 0600)"
    init_new_tmp_peer
    init_placeholder_peer_conf >"${INIT_TMP_PEER}"
    PEER_CONF="${INIT_TMP_PEER}"
    log_info "    (dry run: a placeholder peer config with Endpoint ${HOST_IP}:${INIT_WG_PORT} stands in below)"
    return 0
  fi

  log_info "uploading ${REPO_DIR}/server to ${INIT_HOST}:${INIT_REMOTE_DIR}"
  ssh_argv "${remote_upload}"
  if ! (COPYFILE_DISABLE=1 tar --format ustar -C "${REPO_DIR}" -cf - server | _as_login_user "${SSH_ARGV[@]}"); then
    die "the upload to ${INIT_HOST}:${INIT_REMOTE_DIR} failed (see above)"
  fi
  log_ok "uploaded"

  log_info "running server/install.sh on ${INIT_HOST} (its output follows; keys hidden)"
  ssh_argv "$(init_install_remote)"
  if ! (_as_login_user "${SSH_ARGV[@]}" </dev/null 2>&1 |
    sed -E 's/^([[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=).*/\1 (hidden)/' >&2); then
    log_error "server/install.sh failed on ${INIT_HOST} (see its output above)."
    log_info "Fix the cause and run the same oneexit init again: the server install is idempotent." >&2
    exit 1
  fi
  log_ok "server installed"

  init_new_tmp_peer
  if ! init_ssh "$(init_cat_remote)" >"${INIT_TMP_PEER}"; then
    die "cannot read /etc/wireguard/peers/${INIT_PEER}.conf on ${INIT_HOST}"
  fi
  grep -q '^\[Interface\]' "${INIT_TMP_PEER}" ||
    die "/etc/wireguard/peers/${INIT_PEER}.conf on ${INIT_HOST} is not a WireGuard config"
  PEER_CONF="${INIT_TMP_PEER}"
  log_ok "peer config ${INIT_PEER} fetched (kept only in a mode-0600 temporary file)"
}

init_step4() {
  init_step_header 4 "Client setup"
  setup_client
  [ -n "${HOST_IP}" ] || HOST_IP="${VPS_IP}"
}

init_step5() {
  init_step_header 5 "Hardening"
  setup_harden
}

# init_handshake_seen: 0 once the tunnel reports a handshake.
init_handshake_seen() {
  local dev
  command -v wg >/dev/null 2>&1 || return 1
  dev="$(wg_dev)" || return 1
  wg show "${dev}" latest-handshakes 2>/dev/null | awk '$2 + 0 > 0 { found = 1 } END { exit !found }'
}

# init_leak_test_script: the leak test of this checkout, else the installed one.
init_leak_test_script() {
  local cand
  for cand in "${REPO_DIR}/scripts/leak-test.sh" "${ONEEXIT_LIBEXEC}/leak-test.sh"; do
    if [ -f "${cand}" ]; then
      printf '%s\n' "${cand}"
      return 0
    fi
  done
  return 1
}

# init_box LINE...: the lines in an ASCII box.
init_box() {
  local line width=0
  for line in "$@"; do
    [ "${#line}" -le "${width}" ] || width="${#line}"
  done
  local rule
  rule="$(printf '%*s' "$((width + 2))" '' | tr ' ' '-')"
  printf '+%s+\n' "${rule}"
  for line in "$@"; do
    printf '| %-*s |\n' "${width}" "${line}"
  done
  printf '+%s+\n' "${rule}"
}

init_step6() {
  local i seen=0 leak rc=0 status
  local -a args=()
  init_step_header 6 "Verification"
  if is_dry_run; then
    log_info "[dry-run] wait up to ${INIT_HANDSHAKE_WAIT} s for the first WireGuard handshake (wg show utunN latest-handshakes)"
  else
    i=0
    while [ "${i}" -lt "${INIT_HANDSHAKE_WAIT}" ]; do
      if init_handshake_seen; then
        seen=1
        break
      fi
      sleep 1
      i=$((i + 1))
    done
    if [ "${seen}" -eq 1 ]; then
      log_ok "WireGuard handshake with ${VPS_IP}:${VPS_PORT} after ${i} s"
    else
      log_warn "no WireGuard handshake within ${INIT_HANDSHAKE_WAIT} s: is UDP ${VPS_PORT} open in the provider's firewall? (sudo oneexit doctor)"
    fi
  fi

  leak="$(init_leak_test_script)" || die "leak-test.sh not found"
  args=(--expect-ip "${HOST_IP}")
  is_dry_run && args+=(--dry-run)
  bash "${leak}" "${args[@]}" || rc=$?

  if is_dry_run; then
    status="dry run: nothing was changed"
  elif [ "${rc}" -eq 0 ]; then
    status="kill switch on, all traffic exits through ${HOST_IP}; leak test passed"
  else
    status="leak test FAILED (see above); run: sudo oneexit doctor"
  fi
  printf '\n'
  init_box \
    "oneexit ${ONEEXIT_VERSION}: ${status}" \
    "" \
    "Every day:     oneexit status        tunnel, handshake and public IP" \
    "               sudo oneexit leak-test" \
    "Hotel Wi-Fi:   sudo oneexit portal   (3 minutes to log in to a captive" \
    "               portal; then sudo oneexit lock)" \
    "Undo:          sudo oneexit unharden (privacy settings only)" \
    "               sudo oneexit uninstall (everything on this Mac)" \
    "Logs:          ${ONEEXIT_LOG_DIR}/firewall.log, tunnel.log (oneexit logs)"
  if [ "${rc}" -ne 0 ] && ! is_dry_run; then
    return 1
  fi
  return 0
}

# init_run: the six steps, after init_parse_args (and, in the CLI, after
# the re-run through sudo).
init_run() {
  init_find_repo || die "oneexit init needs the oneexit source tree (server/ next to client/); install with install.sh or git clone"
  require_root
  if [ "${INIT_INTERACTIVE}" -eq 1 ]; then
    init_prompt_server
  fi
  if is_dry_run; then
    log_info "Dry run: no ssh, no network, nothing changed. Commands and files are printed below."
  fi
  init_step1
  init_step2
  init_step3
  init_step4
  init_step5
  init_step6
}

# init_main ARGS...: parse, then the six steps.
init_main() {
  init_parse_args "$@"
  init_run
}
