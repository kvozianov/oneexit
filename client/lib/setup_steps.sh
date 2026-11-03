# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# oneexit client: the steps of the first-run setup as functions, shared by
# client/setup.sh (which runs them all in order) and "oneexit init" (which
# runs them as its steps 1, 4 and 5). Needs common.sh, pf.sh, wgconf.sh and
# privacy.sh. Stock bash 3.2 compatible.
#
# Inputs (globals, set by the caller before the first step):
#   PEER_CONF        the client config printed by server/peer.sh
#   ALLOW_INTERNAL   1 = install even though the boot volume is internal
#   IFACES           space-separated --iface list, empty = auto
#   TIMEZONE REGION  --timezone / --region, empty = derive
#   NO_HARDEN        1 = skip the privacy hardening
#   SETUP_CLIENT_DIR the client/ directory to install from (default SELF_DIR)
#   REPO_DIR         the repository root (scripts/leak-test.sh)
# Outputs (globals): BREW, VPS_IP, VPS_PORT, VPS_HOST, TUNNEL_DNS,
#   PHYS_IFACES, TIMEZONE, REGION.

PEER_CONF="${PEER_CONF:-}"
ALLOW_INTERNAL="${ALLOW_INTERNAL:-0}"
IFACES="${IFACES:-}"
TIMEZONE="${TIMEZONE:-}"
REGION="${REGION:-}"
NO_HARDEN="${NO_HARDEN:-0}"
BREW=""

# setup_client_dir: where client/ files (bin, launchd, lib, the CLI) are
# installed from.
setup_client_dir() {
  printf '%s\n' "${SETUP_CLIENT_DIR:-${SELF_DIR}}"
}

# resolve_path PATH: PATH with every symlink in its last component followed
# (a loop over readlink: BSD readlink has no -f), directory made physical.
resolve_path() {
  local p="$1" dir
  while [ -h "${p}" ]; do
    dir="$(cd -P "$(dirname "${p}")" && pwd)"
    p="$(readlink "${p}")"
    case "${p}" in /*) ;; *) p="${dir}/${p}" ;; esac
  done
  dir="$(cd -P "$(dirname "${p}")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "${dir}" "$(basename "${p}")"
}

# setup_validate_options: --timezone and --region (usage errors, exit 2).
setup_validate_options() {
  if [ -n "${TIMEZONE}" ] && ! tz_is_valid "${TIMEZONE}"; then
    usage_error "unknown time zone: ${TIMEZONE} (no such file in ${ONEEXIT_ZONEINFO}; for example ${PRIVACY_DEFAULT_TIMEZONE})"
  fi
  if [ -n "${REGION}" ]; then
    REGION="$(region_normalize "${REGION}")"
    region_is_valid "${REGION}" || usage_error "invalid region: ${REGION} (two letters, for example ${PRIVACY_DEFAULT_REGION})"
  fi
  return 0
}

# ---------------------------------------------------------------- 1. checks

setup_check_boot_volume() {
  local disk_rc=0
  log_step "Checking the boot volume"
  boot_volume_is_external || disk_rc=$?
  if [ "${disk_rc}" -eq 0 ]; then
    log_ok "macOS is running from an external disk"
  elif [ "${ALLOW_INTERNAL}" -eq 1 ]; then
    log_warn "macOS is not running from an external disk; continuing because of --allow-internal-disk"
  else
    if [ "${disk_rc}" -eq 2 ]; then
      log_error "could not tell which disk macOS is running from (diskutil info / failed)."
    else
      log_error "this Mac is running macOS from its internal disk."
    fi
    cat >&2 <<MSG

oneexit is meant for a separate macOS installed on an external SSD that you
boot only when you need it. Setup installs a kill switch that blocks all
traffic except the WireGuard tunnel from the next boot on, before login.
On your everyday system that would cut off every app that is not meant to
go through your VPS, and it changes DNS and IPv6 for every network service.

diskutil info / reports:
$(boot_volume_summary)

If this really is what you want (a VM, a spare Mac), run again with
--allow-internal-disk. See docs/install-macos-external.md.
MSG
    exit 1
  fi
}

setup_check_pf_hook() {
  local hook_rc=0
  log_step "Checking ${ONEEXIT_PF_CONF} for the com.apple anchor hook"
  pf_conf_has_hook || hook_rc=$?
  if [ "${hook_rc}" -eq 0 ]; then
    log_ok "${ONEEXIT_PF_CONF} evaluates anchor \"com.apple/*\""
  elif [ "${hook_rc}" -eq 2 ] && is_dry_run; then
    log_warn "cannot read ${ONEEXIT_PF_CONF}; a real run would stop here"
  else
    if [ "${hook_rc}" -eq 2 ]; then
      log_error "cannot read ${ONEEXIT_PF_CONF}."
    else
      log_error "${ONEEXIT_PF_CONF} has no 'anchor \"com.apple/*\"' line."
    fi
    cat >&2 <<MSG

oneexit never edits ${ONEEXIT_PF_CONF}. It loads its rules into the anchor
${ONEEXIT_ANCHOR}, and pf only evaluates that anchor when the main ruleset
contains the stock macOS hook:

    anchor "com.apple/*"

Without it the kill switch would load but block nothing. Restore the stock
${ONEEXIT_PF_CONF} (or add the line yourself) and run setup again.
MSG
    exit 1
  fi
}

setup_check_macos() {
  local macos_version macos_major
  if command -v sw_vers >/dev/null 2>&1; then
    macos_version="$(sw_vers -productVersion 2>/dev/null || echo 0)"
    macos_major="${macos_version%%.*}"
    if is_uint "${macos_major}" && [ "${macos_major}" -lt 13 ]; then
      die "macOS 13 or newer is required (found ${macos_version})"
    fi
  else
    log_warn "sw_vers not found; this does not look like macOS"
  fi
}

# setup_find_brew: sets BREW, or stops with how to install Homebrew.
setup_find_brew() {
  local candidate
  log_step "Checking Homebrew"
  BREW=""
  for candidate in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
      BREW="${candidate}"
      break
    fi
  done
  if [ -z "${BREW}" ]; then
    if is_dry_run; then
      log_warn "Homebrew not found; a real run would stop here"
      BREW="brew"
    else
      log_error "Homebrew is required but was not found."
      cat >&2 <<'MSG'

Install it from https://brew.sh first (as your normal user, not with sudo):

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

then run this setup again.
MSG
      exit 1
    fi
  else
    log_ok "Homebrew: ${BREW}"
  fi
}

# setup_preflight: every check that runs before anything is changed.
setup_preflight() {
  setup_check_boot_volume
  setup_check_pf_hook
  setup_check_macos
  setup_find_brew
}

# ---------------------------------------------------------------- 2. packages

setup_brew_install() {
  # Homebrew refuses to run as root; run it as the user who called sudo.
  log_step "Installing wireguard-tools and wireguard-go"
  if is_root && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    run sudo -u "${SUDO_USER}" -H "${BREW}" install wireguard-tools wireguard-go
  elif is_root; then
    die "run setup with sudo from your normal admin account (Homebrew cannot run as root)"
  else
    run "${BREW}" install wireguard-tools wireguard-go
  fi
}

# ---------------------------------------------------------------- 3. peer config

# setup_read_peer_conf: parse PEER_CONF, settle TIMEZONE, REGION, TUNNEL_DNS,
# VPS_IP, VPS_PORT, VPS_HOST and PHYS_IFACES.
setup_read_peer_conf() {
  local parsed endpoint_host endpoint_port wg_address wg_dns entry peer_tz
  local prev_dns="" prev_host="" prev_ip="" prev_timezone=""
  log_step "Reading ${PEER_CONF}"
  parsed="$(parse_wg_conf "${PEER_CONF}")"
  endpoint_host="$(parsed_value "${parsed}" ENDPOINT_HOST)"
  endpoint_port="$(parsed_value "${parsed}" ENDPOINT_PORT)"
  wg_address="$(parsed_value "${parsed}" ADDRESS)"
  wg_dns="$(parsed_value "${parsed}" DNS)"
  [ "$(parsed_value "${parsed}" PRIVATE_KEY_PRESENT)" = "yes" ] ||
    die "${PEER_CONF} has no PrivateKey in [Interface]"
  [ -n "${endpoint_host}" ] || die "${PEER_CONF} has no Endpoint in [Peer]"
  is_port "${endpoint_port}" || die "Endpoint in ${PEER_CONF} needs a port (host:port), got \"${endpoint_port}\""
  [ -n "${wg_address}" ] || log_warn "${PEER_CONF} has no Address in [Interface]"
  case "${endpoint_host}" in
    *:*) die "IPv6 endpoints are not supported (IPv6 is blocked entirely); use the server's IPv4 address" ;;
  esac

  # A previous setup (re-run after "uninstall --keep-keys" on the installed
  # wg0.conf, which has no DNS line and a pinned Endpoint) keeps its values.
  if load_config; then
    prev_dns="${TUNNEL_DNS}"
    prev_host="${VPS_HOST}"
    prev_ip="${VPS_IP}"
    prev_timezone="$(privacy_config_value TIMEZONE || true)"
  fi

  # Time zone of the exit country: --timezone, else the comment the server
  # writes into peer configs, else the previous setup's, else Europe/Berlin.
  if [ -z "${TIMEZONE}" ]; then
    peer_tz="$(privacy_peer_timezone "${PEER_CONF}" || true)"
    if [ -n "${peer_tz}" ] && tz_is_valid "${peer_tz}"; then
      TIMEZONE="${peer_tz}"
      log_ok "time zone ${TIMEZONE} (from the server, in ${PEER_CONF})"
    else
      if [ -n "${peer_tz}" ]; then
        log_warn "ignoring unknown time zone \"${peer_tz}\" in ${PEER_CONF}"
      fi
      if [ -n "${prev_timezone}" ] && tz_is_valid "${prev_timezone}"; then
        TIMEZONE="${prev_timezone}"
        log_ok "time zone ${TIMEZONE} (from the previous setup)"
      else
        TIMEZONE="${PRIVACY_DEFAULT_TIMEZONE}"
        log_ok "time zone ${TIMEZONE} (default; change with --timezone)"
      fi
    fi
  fi
  if [ -z "${REGION}" ]; then
    REGION="$(region_from_timezone "${TIMEZONE}")"
    [ -n "${REGION}" ] || REGION="${PRIVACY_DEFAULT_REGION}"
  fi
  log_ok "region ${REGION}"

  TUNNEL_DNS=""
  for entry in $(printf '%s' "${wg_dns}" | tr ',' ' '); do
    if is_ipv4 "${entry}"; then
      TUNNEL_DNS="${TUNNEL_DNS}${TUNNEL_DNS:+,}${entry}"
    fi
  done
  if [ -z "${TUNNEL_DNS}" ] && [ -n "${prev_dns}" ]; then
    log_ok "no DNS in ${PEER_CONF}; keeping ${prev_dns} from the previous setup"
    TUNNEL_DNS="${prev_dns}"
  elif [ -z "${TUNNEL_DNS}" ]; then
    log_warn "no DNS in ${PEER_CONF}; using ${ONEEXIT_DEFAULT_DNS}"
    TUNNEL_DNS="${ONEEXIT_DEFAULT_DNS}"
  fi

  VPS_IP="$(resolve_host "${endpoint_host}")" ||
    die "cannot resolve ${endpoint_host}; use the server's IPv4 address in Endpoint"
  VPS_PORT="${endpoint_port}"
  if [ "${VPS_IP}" != "${endpoint_host}" ]; then
    log_ok "Endpoint ${endpoint_host} resolved to ${VPS_IP} (stored; pf needs an IP)"
  else
    log_ok "Endpoint ${VPS_IP}:${VPS_PORT}"
  fi

  VPS_HOST="${endpoint_host}"
  if [ "${VPS_IP}" = "${endpoint_host}" ] && [ "${VPS_IP}" = "${prev_ip}" ] && [ -n "${prev_host}" ]; then
    VPS_HOST="${prev_host}"
  fi

  # "auto": oneexit-firewalld re-reads the en* hardware ports on every pass,
  # so an adapter plugged in later works. --iface pins the list.
  if [ -z "${IFACES}" ]; then
    PHYS_IFACES="auto"
    log_ok "physical interfaces: auto (now: $(effective_phys_ifaces))"
  else
    PHYS_IFACES="${IFACES}"
    log_ok "physical interfaces: ${PHYS_IFACES}"
  fi
}

# ---------------------------------------------------------------- 4. files

setup_write_files() {
  local src lib pf_before
  src="$(setup_client_dir)"
  log_step "Writing ${ONEEXIT_CONFIG}"
  run mkdir -p "${ONEEXIT_ETC_DIR}"
  write_file "${ONEEXIT_CONFIG}" 0644 <<CONF
# oneexit client configuration (written by setup.sh)
# Edit VPS_IP / VPS_PORT if the server moves; oneexit-firewalld re-renders the
# pf anchor from this file within a few seconds.
VPS_IP=${VPS_IP}
VPS_PORT=${VPS_PORT}
VPS_HOST=${VPS_HOST}
WG_IFACE_CONF=${ONEEXIT_WG_CONF}
PHYS_IFACES="${PHYS_IFACES}"
TUNNEL_DNS=${TUNNEL_DNS}
TIMEZONE=${TIMEZONE}
REGION=${REGION}
CONF

  log_step "Installing the WireGuard config as ${ONEEXIT_WG_CONF}"
  # wg-quick must not manage DNS (it restores its saved DNS on down and would
  # undo portal/unlock; oneexit sets DNS itself), and the Endpoint is pinned to
  # the IP because a hostname cannot be resolved once DNS points into the tunnel.
  run install -d -m 0700 -o root -g wheel "${ONEEXIT_WG_DIR}"
  render_installed_wg_conf "${PEER_CONF}" "${VPS_IP}" "${VPS_PORT}" |
    write_secret_file "${ONEEXIT_WG_CONF}" 0600
  run chown root:wheel "${ONEEXIT_WG_CONF}"
  log_ok "DNS line removed, Endpoint = ${VPS_IP}:${VPS_PORT}"

  log_step "Installing the oneexit CLI and daemons"
  run install -d -m 0755 -o root -g wheel "$(dirname "${ONEEXIT_BIN}")" "${ONEEXIT_LIBEXEC}" "${ONEEXIT_LIBEXEC}/lib"
  # The bootstrap install.sh links the CLI to its unpacked release; keep that
  # link (copying over it would cut "oneexit init" off from server/).
  if [ -h "${ONEEXIT_BIN}" ] && [ "$(resolve_path "${ONEEXIT_BIN}" || true)" = "$(resolve_path "${src}/oneexit" || true)" ]; then
    log_ok "${ONEEXIT_BIN} links to ${src}/oneexit; keeping the link"
  else
    run install -m 0755 -o root -g wheel "${src}/oneexit" "${ONEEXIT_BIN}"
  fi
  run install -m 0755 -o root -g wheel "${src}/bin/oneexit-firewalld" "${ONEEXIT_LIBEXEC}/oneexit-firewalld"
  run install -m 0755 -o root -g wheel "${src}/bin/oneexit-tunneld" "${ONEEXIT_LIBEXEC}/oneexit-tunneld"
  run install -m 0755 -o root -g wheel "${src}/uninstall.sh" "${ONEEXIT_LIBEXEC}/uninstall.sh"
  run install -m 0755 -o root -g wheel "${REPO_DIR}/scripts/leak-test.sh" "${ONEEXIT_LIBEXEC}/leak-test.sh"
  for lib in common.sh pf.sh wgconf.sh privacy.sh setup_steps.sh init.sh; do
    run install -m 0644 -o root -g wheel "${src}/lib/${lib}" "${ONEEXIT_LIBEXEC}/lib/${lib}"
  done

  log_step "Writing the pf anchor ${ONEEXIT_ANCHOR_FILE}"
  # The tunnel is not up yet: the utun99 placeholder matches nothing, so only
  # DHCP and the endpoint pass until oneexit-firewalld sees the real utun.
  # shellcheck disable=SC2046 # the interface list is space-separated
  render_pf "${VPS_IP}" "${VPS_PORT}" "${ONEEXIT_TUN_PLACEHOLDER}" $(effective_phys_ifaces) |
    write_file "${ONEEXIT_ANCHOR_FILE}" 0644

  log_step "Recording the current pf state"
  if [ -r "${ONEEXIT_STATE_FILE}" ]; then
    log_ok "keeping existing ${ONEEXIT_STATE_FILE} (setup ran before)"
  else
    if pf_enabled; then
      pf_before="yes"
    else
      pf_before="no"
      if ! is_root; then
        log_info "    (pf status needs root to read; assuming it was disabled)"
      fi
    fi
    write_file "${ONEEXIT_STATE_FILE}" 0644 <<STATE
# Written once by setup.sh; read by uninstall.sh.
PF_WAS_ENABLED=${pf_before}
SETUP_EPOCH=$(now_epoch)
STATE
  fi
}

# ---------------------------------------------------------------- 5. network services

setup_network_services() {
  local services service
  log_step "Turning IPv6 off and setting DNS to ${TUNNEL_DNS} on every network service"
  services="$(network_services)"
  if [ -z "${services}" ]; then
    log_warn "no network services found (networksetup missing?)"
  fi
  while IFS= read -r service; do
    [ -n "${service}" ] || continue
    run networksetup -setv6off "${service}" || log_warn "could not turn IPv6 off on \"${service}\""
  done <<EOT
${services}
EOT
  # shellcheck disable=SC2046 # TUNNEL_DNS may hold several servers
  set_dns_all $(printf '%s' "${TUNNEL_DNS}" | tr ',' ' ')
}

# ---------------------------------------------------------------- 6. launchd

setup_launchd() {
  local src label plist attempt
  src="$(setup_client_dir)"
  log_step "Installing launchd daemons"
  run mkdir -p "${ONEEXIT_LOG_DIR}" "${ONEEXIT_RUN_DIR}"
  for label in "${ONEEXIT_FIREWALL_LABEL}" "${ONEEXIT_TUNNEL_LABEL}"; do
    plist="${ONEEXIT_LAUNCHD_DIR}/${label}.plist"
    write_file "${plist}" 0644 <"${src}/launchd/${label}.plist"
    run chown root:wheel "${plist}"
  done

  log_step "Rotating the logs (newsyslog)"
  # The daemons reopen their log on SIGUSR1 (30), sent via their pid files.
  write_file "${ONEEXIT_NEWSYSLOG_CONF}" 0644 <<NEWSYSLOG
# oneexit logs: rotate at 1 MB, keep 5 (written by oneexit setup.sh)
# logfilename                      [owner:group] mode count size(KB) when flags pid_file                           sig
${ONEEXIT_LOG_DIR}/firewall.log    root:wheel    644  5     1024     *    -     ${ONEEXIT_RUN_DIR}/firewalld.pid    30
${ONEEXIT_LOG_DIR}/tunnel.log      root:wheel    644  5     1024     *    -     ${ONEEXIT_RUN_DIR}/tunneld.pid      30
NEWSYSLOG

  log_step "Starting the daemons"
  for label in "${ONEEXIT_FIREWALL_LABEL}" "${ONEEXIT_TUNNEL_LABEL}"; do
    if command -v launchctl >/dev/null 2>&1 && launchctl print "system/${label}" >/dev/null 2>&1; then
      run launchctl bootout "system/${label}" || true
    fi
    # wireguard-go outlives its daemon (AbandonProcessGroup); on a re-run take
    # the old tunnel down so the new daemon starts it from the new wg0.conf.
    if [ "${label}" = "${ONEEXIT_TUNNEL_LABEL}" ] && wg_tunnel_up; then
      run wg-quick down "${ONEEXIT_WG_CONF}" || log_warn "wg-quick down failed"
    fi
    run launchctl enable "system/${label}"
    # Right after a bootout launchd can answer "Bootstrap failed: 5"; retry.
    attempt=1
    until run launchctl bootstrap system "${ONEEXIT_LAUNCHD_DIR}/${label}.plist"; do
      if [ "${attempt}" -ge 5 ]; then
        die "launchctl bootstrap ${label} failed ${attempt} times; see: sudo launchctl print system/${label}"
      fi
      log_warn "launchctl bootstrap ${label} failed; retrying (${attempt}/5)"
      attempt=$((attempt + 1))
      sleep 1
    done
  done
}

# setup_client: everything between the checks and the hardening.
setup_client() {
  setup_brew_install
  setup_read_peer_conf
  setup_write_files
  setup_network_services
  setup_launchd
}

# ---------------------------------------------------------------- 7. hardening

setup_harden() {
  if [ "${NO_HARDEN}" -eq 1 ]; then
    log_step "Skipping the privacy hardening (--no-harden)"
    log_info "    later: sudo oneexit harden   (uses TIMEZONE=${TIMEZONE} and REGION=${REGION} from the config)"
  else
    log_step "Hardening macOS: Location Services, time zone, region, computer name, WebRTC"
    harden_apply "${TIMEZONE}" "${REGION}" "$(privacy_user)" ||
      log_warn "some privacy settings were not changed; see above, and run: sudo oneexit doctor"
  fi
}

# ---------------------------------------------------------------- 8. next steps

setup_next_steps() {
  log_step "Done"
  cat <<NEXT

The kill switch is active: only UDP to ${VPS_IP}:${VPS_PORT} and DHCP leave the
physical interfaces; everything else must go through the WireGuard tunnel.

Next steps:
  oneexit status              pf, tunnel and handshake at a glance
  sudo oneexit leak-test      check IPv4, IPv6, DNS and direct-interface leaks
  sudo oneexit portal         3 minutes to log in to a hotel or airport captive portal
  sudo oneexit doctor         full diagnostics if something does not work

Logs: ${ONEEXIT_LOG_DIR}/firewall.log and tunnel.log (oneexit logs).
Undo the privacy changes only: sudo oneexit unharden
Undo everything: sudo oneexit uninstall
NEXT
  if is_dry_run; then
    log_info "(dry run: nothing was changed)"
  fi
}
