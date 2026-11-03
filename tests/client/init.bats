#!/usr/bin/env bats
# "oneexit init": target parsing, the ssh command builders, and the dry run of
# the six steps. No test reaches a server: fixtures/bin/ssh fails loudly and
# records every call, and a dry run must not call ssh, tar or curl at all.

load ../helpers/client_helpers

setup() {
  client_test_env
  export FAKE_CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : >"${FAKE_CALL_LOG}"
  export FAKE_DISK=external
}

# init_dry ARGS...: oneexit init ARGS --dry-run, stdin not a terminal.
init_dry() {
  run "${CLIENT_DIR}/oneexit" init "$@" --dry-run </dev/null
}

# line_of TEXT: number of the first output line containing TEXT (0 if none).
line_of() {
  printf '%s\n' "${output}" | awk -v want="$1" 'index($0, want) { print NR; found = 1; exit } END { if (!found) print 0 }'
}

# ---------------------------------------------------------------- pure functions

@test "parse_server_target: root@1.2.3.4" {
  load_init_libs
  run parse_server_target root@1.2.3.4
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf 'USER=root\nHOST=1.2.3.4\nPORT=22')" ]
}

@test "parse_server_target: host:2222 defaults the user to root" {
  load_init_libs
  run parse_server_target vps.example.com:2222
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf 'USER=root\nHOST=vps.example.com\nPORT=2222')" ]
}

@test "parse_server_target: user@host:2222 and a bare IPv4" {
  load_init_libs
  run parse_server_target deploy@192.168.64.1:2222
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf 'USER=deploy\nHOST=192.168.64.1\nPORT=2222')" ]
  run parse_server_target 203.0.113.5
  [ "${output}" = "$(printf 'USER=root\nHOST=203.0.113.5\nPORT=22')" ]
}

@test "parse_server_target rejects garbage with exit 2" {
  load_init_libs
  for bad in "" "root@" "@host" "host:" "host:0" "host:70000" "host:22x" "a@b@c" \
    "999.1.1.1" "1.2.3" "-oProxyCommand=x" "root@-host" "host name" "[2001:db8::1]:22" \
    "2001:db8::1" "ho_st" "host..example" "-root@host" 'root;id@host' 'root@host;id'; do
    run parse_server_target "${bad}"
    if [ "${status}" -ne 2 ]; then
      echo "accepted: '${bad}' (status ${status}, output ${output})"
      return 1
    fi
  done
}

@test "remote_sudo_prefix: nothing for root, sudo -n otherwise" {
  load_init_libs
  [ -z "$(remote_sudo_prefix root)" ]
  [ "$(remote_sudo_prefix deploy)" = "sudo -n" ]
}

@test "ssh_cmd: batch mode, timeout, first-seen host keys, --ssh-key and the port" {
  load_init_libs
  init_set_target deploy@192.168.64.1:2222
  INIT_SSH_KEY="/Users/me/.ssh/id oneexit"
  run ssh_cmd "sudo -n true"
  [ "${status}" -eq 0 ]
  [ "${output}" = "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i '/Users/me/.ssh/id oneexit' -p 2222 deploy@192.168.64.1 'sudo -n true'" ]
  init_set_target root@203.0.113.5
  INIT_SSH_KEY=""
  run ssh_cmd true
  [ "${output}" = "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new root@203.0.113.5 true" ]
}

@test "time zone default: the server's zone unless UTC, then Europe/Berlin; region from the zone" {
  load_init_libs
  [ "$(init_default_timezone Europe/Amsterdam)" = "Europe/Amsterdam" ]
  [ "$(init_default_timezone UTC)" = "Europe/Berlin" ]
  [ "$(init_default_timezone Etc/UTC)" = "Europe/Berlin" ]
  [ "$(init_default_timezone "")" = "Europe/Berlin" ]
  [ "$(init_default_timezone Mars/Olympus)" = "Europe/Berlin" ]
  [ "$(init_default_region Europe/Amsterdam)" = "NL" ]
  [ "$(init_default_region UTC)" = "DE" ]
}

@test "the remote upload re-creates /opt/oneexit with mkdir (no -p) before tar" {
  load_init_libs
  init_set_target deploy@203.0.113.5
  run init_upload_remote
  [ "${output}" = "sudo -n rm -rf /opt/oneexit && sudo -n mkdir -m 0700 /opt/oneexit && sudo -n tar -C /opt/oneexit --no-same-owner -xf -" ]
}

# ---------------------------------------------------------------- init --server --dry-run

@test "init --server --dry-run prints the six steps in order" {
  init_dry --server root@203.0.113.5
  [ "${status}" -eq 0 ]
  local prev=0 n step
  for step in "Step 1/6: Pre-flight checks" "Step 2/6: Server reachability" \
    "Step 3/6: Installing the server on 203.0.113.5" "Step 4/6: Client setup" \
    "Step 5/6: Hardening" "Step 6/6: Verification"; do
    n="$(line_of "==> ${step}")"
    if [ "${n}" -le "${prev}" ]; then
      echo "out of order or missing: ${step}"
      return 1
    fi
    prev="${n}"
  done
}

@test "init --server --dry-run prints the ssh, tar, install.sh and cat commands in order" {
  init_dry --server root@203.0.113.5
  [ "${status}" -eq 0 ]
  local ssh="ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new root@203.0.113.5"
  [[ "${output}" == *"[dry-run] ${ssh} true"* ]]
  [[ "${output}" == *"[dry-run] ${ssh} 'timedatectl show -p Timezone --value'"* ]]
  [[ "${output}" == *"[dry-run] COPYFILE_DISABLE=1 tar --format ustar -C ${REPO_ROOT} -cf - server | ${ssh} 'rm -rf /opt/oneexit && mkdir -m 0700 /opt/oneexit && tar -C /opt/oneexit --no-same-owner -xf -'"* ]]
  [[ "${output}" == *"[dry-run] ${ssh} 'bash /opt/oneexit/server/install.sh --endpoint 203.0.113.5 --port 51820 --peer mac --timezone Europe/Berlin' >&2"* ]]
  [[ "${output}" == *"[dry-run] ${ssh} 'cat /etc/wireguard/peers/mac.conf'"* ]]
  [ "$(line_of "${ssh} true")" -lt "$(line_of "| ${ssh} 'rm -rf")" ]
  [ "$(line_of "| ${ssh} 'rm -rf")" -lt "$(line_of "server/install.sh --endpoint")" ]
  [ "$(line_of "server/install.sh --endpoint")" -lt "$(line_of "cat /etc/wireguard/peers/mac.conf")" ]
  [ "$(line_of "cat /etc/wireguard/peers/mac.conf")" -lt "$(line_of "Step 4/6")" ]
}

@test "init --server --dry-run then shows the setup, harden and leak-test dry runs" {
  init_dry --server root@203.0.113.5
  [ "${status}" -eq 0 ]
  cfg="$(dry_run_block "${output}" "${ONEEXIT_CONFIG}")"
  [[ "${cfg}" == *"VPS_IP=203.0.113.5"* ]]
  [[ "${cfg}" == *"VPS_PORT=51820"* ]]
  [[ "${cfg}" == *"TIMEZONE=Europe/Berlin"* ]]
  [[ "${cfg}" == *"REGION=DE"* ]]
  [[ "${output}" == *"[dry-run] launchctl bootstrap system ${ONEEXIT_LAUNCHD_DIR}/com.oneexit.tunnel.plist"* ]]
  [[ "${output}" == *"| pass out quick on { en0 en7 } proto udp from any to 203.0.113.5 port 51820 keep state"* ]]
  [[ "${output}" == *"[dry-run] systemsetup -settimezone Europe/Berlin"* ]]
  [[ "${output}" == *"[dry-run] scutil --set ComputerName Mac"* ]]
  [[ "${output}" == *"[dry-run] wait up to 30 s for the first WireGuard handshake"* ]]
  [[ "${output}" == *"SKIP  ipv4       dry-run"* ]]
  [[ "${output}" == *"0 FAIL(s)"* ]]
  [ "$(line_of "Step 5/6")" -lt "$(line_of "systemsetup -settimezone")" ]
  [ "$(line_of "Step 6/6")" -lt "$(line_of "SKIP  ipv4")" ]
}

@test "init --server --dry-run ends with the summary box: status, portal, undo, logs" {
  init_dry --server root@203.0.113.5
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dry run: nothing was changed"* ]]
  [[ "${output}" == *"sudo oneexit portal"* ]]
  [[ "${output}" == *"sudo oneexit uninstall"* ]]
  [[ "${output}" == *"${ONEEXIT_LOG_DIR}/firewall.log"* ]]
  [ "$(printf '%s\n' "${output}" | tail -n 1 | tr -d '+-')" = "" ]
}

@test "init --dry-run makes no ssh, tar or curl call and writes nothing" {
  init_dry --server root@203.0.113.5
  [ "${status}" -eq 0 ]
  [ ! -s "${FAKE_CALL_LOG}" ] || {
    cat "${FAKE_CALL_LOG}"
    return 1
  }
  [ ! -e "${ONEEXIT_CONFIG}" ]
  [ ! -e "${ONEEXIT_WG_CONF}" ]
  [[ "${output}" != *"ssh stub"* ]]
  [[ "${output}" != *"DRYRUNplaceholderPRIVATEkey"* ]]
}

@test "init --dry-run with a non-root login prefixes every remote command with sudo -n" {
  init_dry --server deploy@203.0.113.5:2222
  [ "${status}" -eq 0 ]
  local ssh="ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p 2222 deploy@203.0.113.5"
  [[ "${output}" == *"[dry-run] ${ssh} 'sudo -n true'"* ]]
  [[ "${output}" == *"[dry-run] ${ssh} 'sudo -n timedatectl show -p Timezone --value'"* ]]
  [[ "${output}" == *"${ssh} 'sudo -n rm -rf /opt/oneexit && sudo -n mkdir -m 0700 /opt/oneexit && sudo -n tar -C /opt/oneexit --no-same-owner -xf -'"* ]]
  [[ "${output}" == *"[dry-run] ${ssh} 'sudo -n bash /opt/oneexit/server/install.sh --endpoint 203.0.113.5 --port 51820 --peer mac --timezone Europe/Berlin' >&2"* ]]
  [[ "${output}" == *"[dry-run] ${ssh} 'sudo -n cat /etc/wireguard/peers/mac.conf'"* ]]
}

@test "init --dry-run for the VM lab: root@192.168.64.1:2222 with --ssh-key" {
  init_dry --server root@192.168.64.1:2222 --ssh-key "${BATS_TEST_TMPDIR}/lab_key" --peer lab
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"-i ${BATS_TEST_TMPDIR}/lab_key -p 2222 root@192.168.64.1 'bash /opt/oneexit/server/install.sh --endpoint 192.168.64.1 --port 51820 --peer lab"* ]]
  [[ "${output}" != *"sudo -n"* ]]
}

@test "init --dry-run passes --port, --peer, --timezone and --region through" {
  init_dry --server root@203.0.113.5 --port 443 --peer laptop --timezone Europe/Amsterdam
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"'bash /opt/oneexit/server/install.sh --endpoint 203.0.113.5 --port 443 --peer laptop --timezone Europe/Amsterdam'"* ]]
  [[ "${output}" == *"'cat /etc/wireguard/peers/laptop.conf'"* ]]
  [[ "${output}" != *"timedatectl"* ]]
  cfg="$(dry_run_block "${output}" "${ONEEXIT_CONFIG}")"
  [[ "${cfg}" == *"VPS_PORT=443"* ]]
  [[ "${cfg}" == *"TIMEZONE=Europe/Amsterdam"* ]]
  [[ "${cfg}" == *"REGION=NL"* ]]
  init_dry --server root@203.0.113.5 --timezone Europe/Amsterdam --region de
  [[ "$(dry_run_block "${output}" "${ONEEXIT_CONFIG}")" == *"REGION=DE"* ]]
}

@test "init --dry-run does not resolve a hostname (no network) and says what stands in" {
  init_dry --server root@vps.example.com
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"resolve vps.example.com to its IPv4 address (192.0.2.1 stands in for it below)"* ]]
  [[ "${output}" == *"root@vps.example.com 'bash /opt/oneexit/server/install.sh --endpoint 192.0.2.1 "* ]]
}

@test "init --no-harden skips the hardening commands" {
  init_dry --server root@203.0.113.5 --no-harden
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Skipping the privacy hardening (--no-harden)"* ]]
  [[ "${output}" != *"systemsetup -settimezone"* ]]
}

@test "init --dry-run refuses an internal boot disk before any server step" {
  FAKE_DISK=internal init_dry --server root@203.0.113.5
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--allow-internal-disk"* ]]
  [[ "${output}" != *"Step 2/6"* ]]
  FAKE_DISK=internal init_dry --server root@203.0.113.5 --allow-internal-disk
  [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------- init --config

@test "init --config peer-tz.conf --dry-run: Europe/Amsterdam, region NL, no server steps" {
  init_dry --config "${FIXTURES}/peer-tz.conf"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Step 2/6: Server: skipped"* ]]
  [[ "${output}" == *"Step 3/6: Server install: skipped"* ]]
  [[ "${output}" == *"time zone Europe/Amsterdam (from the server, in ${FIXTURES}/peer-tz.conf)"* ]]
  cfg="$(dry_run_block "${output}" "${ONEEXIT_CONFIG}")"
  [[ "${cfg}" == *"TIMEZONE=Europe/Amsterdam"* ]]
  [[ "${cfg}" == *"REGION=NL"* ]]
  [[ "${output}" == *"[dry-run] systemsetup -settimezone Europe/Amsterdam"* ]]
  [[ "${output}" == *"Step 6/6: Verification"* ]]
  [[ "${output}" != *"ssh -o"* ]]
  [ ! -s "${FAKE_CALL_LOG}" ]
}

# ---------------------------------------------------------------- usage

@test "init with no arguments and no terminal exits 2 with usage" {
  run "${CLIENT_DIR}/oneexit" init </dev/null
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"no server given"* ]]
  [[ "${output}" == *"Usage: sudo oneexit init --server"* ]]
  [ ! -s "${FAKE_CALL_LOG}" ]
}

@test "init usage errors: bad --server, --server with --config, bad --port, --peer, --timezone" {
  init_dry --server 'root@bad host'
  [ "${status}" -eq 2 ]
  init_dry --server root@203.0.113.5 --config "${FIXTURES}/peer.conf"
  [ "${status}" -eq 2 ]
  init_dry --server root@203.0.113.5 --port 0
  [ "${status}" -eq 2 ]
  init_dry --server root@203.0.113.5 --peer 'my mac'
  [ "${status}" -eq 2 ]
  init_dry --server root@203.0.113.5 --timezone Mars/Olympus
  [ "${status}" -eq 2 ]
  init_dry --server root@203.0.113.5 --frobnicate
  [ "${status}" -eq 2 ]
  [ ! -s "${FAKE_CALL_LOG}" ]
}

@test "init --help and oneexit --help describe init" {
  run "${CLIENT_DIR}/oneexit" init --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--server [USER@]HOST[:SSHPORT]"* ]]
  [[ "${output}" == *"--ssh-key PATH"* ]]
  [[ "${output}" == *"--config PATH"* ]]
  run "${CLIENT_DIR}/oneexit" --help
  printf '%s\n' "${output}" | grep -Eq '^  init( |$)'
}

# ---------------------------------------------------------------- symlinks

@test "oneexit init runs through a chain of relative symlinks (as linked by install.sh)" {
  mkdir -p "${BATS_TEST_TMPDIR}/share/bin" "${BATS_TEST_TMPDIR}/usr/bin"
  ln -s "${REPO_ROOT}" "${BATS_TEST_TMPDIR}/share/0.2.0"
  ln -s ../0.2.0/client/oneexit "${BATS_TEST_TMPDIR}/share/bin/oneexit"
  ln -s ../../share/bin/oneexit "${BATS_TEST_TMPDIR}/usr/bin/oneexit"
  run "${BATS_TEST_TMPDIR}/usr/bin/oneexit" init --server root@203.0.113.5 --dry-run </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Step 6/6: Verification"* ]]
  [[ "${output}" == *"tar --format ustar -C ${REPO_ROOT} -cf - server"* ]]
}

@test "setup keeps a /usr/local/bin/oneexit symlink to the same CLI instead of copying over it" {
  mkdir -p "$(dirname "${ONEEXIT_BIN}")"
  ln -s "${CLIENT_DIR}/oneexit" "${ONEEXIT_BIN}"
  init_dry --config "${FIXTURES}/peer.conf"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${ONEEXIT_BIN} links to ${CLIENT_DIR}/oneexit; keeping the link"* ]]
  [[ "${output}" != *"client/oneexit ${ONEEXIT_BIN}"* ]]
}

@test "interactive prompts: the server address is asked again until it parses; defaults on Enter" {
  load_init_libs
  init_prompt_server 2>/dev/null <<'IN'
root@bad host
deploy@203.0.113.5:2222
IN
  [ "${INIT_USER}" = "deploy" ]
  [ "${INIT_HOST}" = "203.0.113.5" ]
  [ "${INIT_SSH_PORT}" = "2222" ]
  TIMEZONE="Europe/Amsterdam"
  init_prompt_privacy 2>/dev/null <<'IN'


IN
  [ "${TIMEZONE}" = "Europe/Amsterdam" ]
  [ "${REGION}" = "NL" ]
  TIMEZONE="Europe/Berlin"
  REGION=""
  init_prompt_privacy 2>/dev/null <<'IN'
Mars/Olympus
Europe/Amsterdam
de
IN
  [ "${TIMEZONE}" = "Europe/Amsterdam" ]
  [ "${REGION}" = "DE" ]
}
