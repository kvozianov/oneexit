#!/usr/bin/env bash
# shellcheck disable=SC2024 # runs as the runner user; root-only values are read with sudo into files that user owns
# Real run of the bootstrap and of "oneexit harden" / "oneexit unharden" on a
# GitHub-hosted macOS runner (.github/workflows/macos-real.yml). It changes
# the system settings of the machine it runs on, so it refuses to run anywhere
# else: it needs GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=github-hosted, macOS
# and ONEEXIT_REAL_RUN=1.
#
#   bash tests/macos-real/real-run.sh bootstrap|baseline|harden|unharden|idempotence|summary
#
# Each phase records its checks in OUT/results.tsv (phase, check, PASS/FAIL/INFO,
# observed, expected) and exits 1 if one of its own checks failed. The phases
# share OUT (default: RUNNER_TEMP/macos-real), which the workflow uploads.
# Values are read with the same commands a person would type, not with the
# product's own probes, so a wrong probe in privacy.sh cannot hide a wrong write.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${REPO}/client/oneexit"
OUT="${ONEEXIT_REAL_OUT:-${RUNNER_TEMP:-/tmp}/macos-real}"
RESULTS="${OUT}/results.tsv"

TZ_WANT="Europe/Berlin"
REGION_WANT="DE"
GENERIC_NAME="Mac"
WEBRTC_WANT="disable_non_proxied_udp"
ETC_DIR="/usr/local/etc/oneexit"
CONFIG="${ETC_DIR}/config"
STATE="${ETC_DIR}/privacy-state"
LOCATIOND_DOMAIN="/var/db/locationd/Library/Preferences/ByHost/com.apple.locationd"
LOCATIOND_BYHOST_DIR="/var/db/locationd/Library/Preferences/ByHost"
TZAUTO_DOMAIN="/Library/Preferences/com.apple.timezone.auto"
CHROME_BUNDLES="com.google.Chrome com.brave.Browser com.microsoft.Edge org.chromium.Chromium"
FIREFOX_APP="/Applications/Firefox.app"
FIREFOX_POLICY="${FIREFOX_APP}/Contents/Resources/distribution/policies.json"
# Keys of a snapshot that unharden has to bring back exactly.
RESTORE_KEYS="TIMEZONE LOCALTIME DATE_ZONE TZ_AUTO LOCATION LOCATION_CURRENTHOST LOCATION_NOTBACKEDUP LOCATION_API
COMPUTER_NAME HOST_NAME LOCAL_HOST_NAME APPLE_LOCALE APPLE_LANGUAGES
WEBRTC_com.google.Chrome WEBRTC_com.brave.Browser WEBRTC_com.microsoft.Edge WEBRTC_org.chromium.Chromium
FIREFOX_POLICY LOOKUP_SUGGESTIONS_DISABLED SAFARI_UNIVERSAL_SEARCH"

PHASE_FAILS=0

guard() {
  if [ "${GITHUB_ACTIONS:-}" != "true" ] || [ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ] ||
    [ "$(uname -s)" != "Darwin" ] || [ "${ONEEXIT_REAL_RUN:-}" != "1" ]; then
    echo "error: this script changes the system settings of the Mac it runs on." >&2
    echo "It only runs on a GitHub-hosted macOS runner (see .github/workflows/macos-real.yml)." >&2
    exit 2
  fi
  mkdir -p "${OUT}"
  touch "${RESULTS}"
}

# record PHASE CHECK STATUS OBSERVED EXPECTED
record() {
  local phase="$1" name="$2" status="$3" observed="$4" expected="$5"
  printf '%s\t%s\t%s\t%s\t%s\n' "${phase}" "${name}" "${status}" \
    "$(printf '%s' "${observed}" | tr '\t\n' '  ')" "$(printf '%s' "${expected}" | tr '\t\n' '  ')" >>"${RESULTS}"
  printf '%-5s %-34s observed: %s | expected: %s\n' "${status}" "${name}" "${observed}" "${expected}"
  [ "${status}" != "FAIL" ] || PHASE_FAILS=$((PHASE_FAILS + 1))
  return 0
}

# expect_eq PHASE CHECK OBSERVED EXPECTED
expect_eq() {
  if [ "$3" = "$4" ]; then record "$1" "$2" PASS "$3" "$4"; else record "$1" "$2" FAIL "$3" "$4"; fi
}

phase_end() {
  if [ "${PHASE_FAILS}" -gt 0 ]; then
    echo "${PHASE_FAILS} check(s) failed in this phase"
    exit 1
  fi
}

# ---------------------------------------------------------------- probes

or_absent() {
  local v
  v="$(cat)"
  if [ -n "${v}" ]; then printf '%s\n' "${v}"; else echo "<absent>"; fi
}

root_default() { sudo defaults read "$@" 2>/dev/null | head -n 1 | or_absent; }
user_default() { defaults read "$@" 2>/dev/null | head -n 1 | or_absent; }

languages() {
  defaults read -g AppleLanguages 2>/dev/null |
    sed -e 's/[[:space:]]//g' -e 's/"//g' -e 's/,$//' | grep -v -e '^($' -e '^)$' -e '^$' |
    paste -s -d ';' - | or_absent
}

name_of() {
  local v
  v="$(scutil --get "$1" 2>/dev/null)" || v=""
  printf '%s' "${v}" | head -n 1 | or_absent
}

timezone_now() {
  sudo systemsetup -gettimezone 2>/dev/null | sed -n 's/^Time Zone: //p' | head -n 1 | or_absent
}

# location_api: what CoreLocation itself reports (asks locationd over XPC):
# true, false or unknown. JavaScript for Automation first; swift as fallback.
location_api() {
  local v=""
  v="$(perl -e 'alarm shift; exec @ARGV' 30 osascript -l JavaScript \
    -e 'ObjC.import("CoreLocation"); $.CLLocationManager.locationServicesEnabled' 2>/dev/null)" || v=""
  case "${v}" in
    true | false) ;;
    *)
      v="$(printf 'import CoreLocation\nprint(CLLocationManager.locationServicesEnabled())\n' |
        perl -e 'alarm shift; exec @ARGV' 120 swift - 2>/dev/null | tail -n 1)" || v=""
      ;;
  esac
  case "${v}" in
    true | false) printf '%s\n' "${v}" ;;
    *) echo "unknown" ;;
  esac
}

# snapshot LABEL: every value harden touches, as KEY=value lines in OUT/LABEL.env.
snapshot() {
  local label="$1" file="${OUT}/$1.env" bundle
  {
    printf 'TIMEZONE=%s\n' "$(timezone_now)"
    printf 'LOCALTIME=%s\n' "$(readlink /etc/localtime 2>/dev/null | or_absent)"
    printf 'DATE_ZONE=%s\n' "$(date +%Z)"
    printf 'TZ_AUTO=%s\n' "$(root_default "${TZAUTO_DOMAIN}" Active)"
    printf 'LOCATION=%s\n' "$(root_default "${LOCATIOND_DOMAIN}" LocationServicesEnabled)"
    # The ByHost domain the way CFPreferences resolves it for the locationd
    # user (the file with the hardware UUID in its name).
    printf 'LOCATION_CURRENTHOST=%s\n' "$(sudo -u _locationd -H defaults -currentHost read com.apple.locationd LocationServicesEnabled 2>/dev/null | head -n 1 | or_absent)"
    printf 'LOCATION_NOTBACKEDUP=%s\n' "$(sudo -u _locationd -H defaults -currentHost read com.apple.locationd.notbackedup LocationServicesEnabled 2>/dev/null | head -n 1 | or_absent)"
    printf 'LOCATION_API=%s\n' "$(location_api)"
    printf 'COMPUTER_NAME=%s\n' "$(name_of ComputerName)"
    printf 'HOST_NAME=%s\n' "$(name_of HostName)"
    printf 'LOCAL_HOST_NAME=%s\n' "$(name_of LocalHostName)"
    printf 'APPLE_LOCALE=%s\n' "$(user_default -g AppleLocale)"
    printf 'APPLE_LANGUAGES=%s\n' "$(languages)"
    for bundle in ${CHROME_BUNDLES}; do
      printf 'WEBRTC_%s=%s\n' "${bundle}" "$(root_default "/Library/Preferences/${bundle}" WebRtcIPHandlingPolicy)"
    done
    if [ -d "${FIREFOX_APP}" ]; then
      printf 'FIREFOX_INSTALLED=yes\n'
    else
      printf 'FIREFOX_INSTALLED=no\n'
    fi
    if [ -e "${FIREFOX_POLICY}" ]; then
      printf 'FIREFOX_POLICY=present:%s\n' "$(shasum -a 256 "${FIREFOX_POLICY}" | awk '{ print substr($1, 1, 12) }')"
    else
      printf 'FIREFOX_POLICY=<absent>\n'
    fi
    printf 'LOOKUP_SUGGESTIONS_DISABLED=%s\n' "$(user_default com.apple.lookup.shared LookupSuggestionsDisabled)"
    printf 'SAFARI_UNIVERSAL_SEARCH=%s\n' "$(user_default com.apple.Safari UniversalSearchEnabled)"
    if sudo test -e "${STATE}"; then
      printf 'PRIVACY_STATE=present\n'
    else
      printf 'PRIVACY_STATE=<absent>\n'
    fi
    printf 'LOCATIOND_PID=%s\n' "$(pgrep -x locationd | head -n 1 | or_absent)"
  } >"${file}"
  {
    echo "--- ls -la ${LOCATIOND_BYHOST_DIR}"
    sudo ls -la "${LOCATIOND_BYHOST_DIR}" 2>&1 || true
    echo "--- locationd preference files"
    sudo find "${LOCATIOND_BYHOST_DIR}" -name 'com.apple.locationd*' -print -exec plutil -p {} \; 2>&1 || true
  } >"${OUT}/${label}-locationd-files.txt"
  echo "--- snapshot ${label}"
  cat "${file}"
}

# value LABEL KEY
value() {
  sed -n "s/^$2=//p" "${OUT}/$1.env" | head -n 1
}

# locationd_log LABEL: the last 2 minutes of locationd's log (the kickstart
# was a few seconds ago) in OUT/locationd-LABEL.log; prints the
# locationServicesEnabledStatus that the running locationd logged when it
# started (1 on, 0 off), or "unknown".
locationd_log() {
  local label="$1" pid status
  pid="$(pgrep -x locationd | head -n 1 || true)"
  sudo log show --last 2m --style compact --predicate 'process == "locationd"' >"${OUT}/locationd-${label}.log" 2>&1 || true
  status="$(grep -F "locationd[${pid}:" "${OUT}/locationd-${label}.log" |
    sed -n 's/.*"locationServicesEnabledStatus":\([0-9-]*\).*/\1/p' | tail -n 1)"
  {
    echo "--- locationd log (${label}): $(wc -l <"${OUT}/locationd-${label}.log" | tr -d ' ') lines, pid ${pid:-none}; state lines:"
    grep -F "locationd[${pid}:" "${OUT}/locationd-${label}.log" |
      grep -E 'locationServicesEnabledStatus|disabled system-wide|Location services are' | head -n 5 || true
  } >&2
  printf '%s\n' "${status:-unknown}"
}

# enable_location: the runner image ships with Location Services off, which
# would make harden's switch invisible. Scaffolding: turn them on the way the
# preference is stored for the locationd user (its ByHost domain, plus the
# "notbackedup" copy that macOS 15 keeps next to it), restart locationd, and
# check that CoreLocation reports them on. Written with -currentHost as
# _locationd, not with the path privacy.sh uses, so the two cross-check.
enable_location() {
  local api status
  sudo -u _locationd -H defaults -currentHost write com.apple.locationd LocationServicesEnabled -int 1
  sudo launchctl kickstart -k system/com.apple.locationd
  sleep 5
  api="$(location_api)"
  status="$(locationd_log enable-1)"
  record baseline "enable Location Services (ByHost only)" INFO "CoreLocation ${api}, locationd status ${status}" "true / 1"
  if [ "${api}" != "true" ]; then
    sudo -u _locationd -H defaults -currentHost write com.apple.locationd.notbackedup LocationServicesEnabled -int 1
    sudo launchctl kickstart -k system/com.apple.locationd
    sleep 5
    api="$(location_api)"
    status="$(locationd_log enable-2)"
    record baseline "enable Location Services (+ notbackedup)" INFO "CoreLocation ${api}, locationd status ${status}" "true / 1"
  fi
  if [ "${api}" = "true" ]; then
    record baseline "Location Services on before harden" PASS "${api}" "true"
  else
    record baseline "Location Services on before harden" FAIL "${api}" "true (scaffolding could not turn them on)"
  fi
}

# run_cli LOG ARGS...: sudo client/oneexit ARGS, output to OUT/LOG and the job
# log; prints the exit code.
run_cli() {
  local log="$1" rc=0
  shift
  sudo "${CLI}" "$@" >"${OUT}/${log}" 2>&1 || rc=$?
  sed 's/^/    | /' "${OUT}/${log}" >&2
  printf '%s\n' "${rc}"
}

privacy_line() {
  sed -n 's/^  privacy:[[:space:]]*//p' "${OUT}/$1" | head -n 1
}

# leak_json LABEL: run the leak test through the CLI. Checks 1-8 need the
# tunnel and fail on the runner (exit 1); the JSON is what matters.
leak_json() {
  local label="$1" rc=0
  sudo "${CLI}" leak-test --json >"${OUT}/leak-test-${label}.json" 2>"${OUT}/leak-test-${label}.stderr" || rc=$?
  echo "--- leak-test --json (${label}), exit ${rc}"
  cat "${OUT}/leak-test-${label}.json"
  printf '%s\n' "${rc}" >"${OUT}/leak-test-${label}.rc"
}

# leak_status LABEL CHECK: STATUS<TAB>reason of one check from the JSON.
leak_status() {
  python3 -I - "${OUT}/leak-test-$1.json" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for item in data:
    if item.get("check") == sys.argv[2]:
        print(item.get("status", "") + "\t" + item.get("reason", ""))
        break
else:
    print("MISSING\tno such check in the JSON")
PY
}

# ---------------------------------------------------------------- phases

phase_bootstrap() {
  local pinned sha link target rc=0 out resolved
  pinned="$(sed -n 's/^ONEEXIT_VERSION="\(.*\)"$/\1/p' "${REPO}/install.sh")"
  sha="$(sed -n 's/^ONEEXIT_SHA256="\(.*\)"$/\1/p' "${REPO}/install.sh")"
  echo "pinned version ${pinned}, sha256 ${sha}"
  # The README one-liner, with the checked-out file in place of the curl:
  #   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kvozianov/oneexit/main/install.sh)"
  (cd "${REPO}" && /bin/bash -c "$(cat install.sh)") >"${OUT}/bootstrap.log" 2>&1 || rc=$?
  sed 's/^/    | /' "${OUT}/bootstrap.log"
  expect_eq bootstrap "install.sh exit code" "${rc}" 0
  if grep -q "^ok: sha256 ${sha}$" "${OUT}/bootstrap.log"; then
    record bootstrap "sha256 verified" PASS "ok: sha256 ${sha:0:12}..." "pinned ${sha:0:12}..."
  else
    record bootstrap "sha256 verified" FAIL "$(grep -i sha256 "${OUT}/bootstrap.log" | head -n 1)" "ok: sha256 ${sha:0:12}..."
  fi
  link="$(readlink /usr/local/bin/oneexit 2>/dev/null || echo "<no symlink>")"
  expect_eq bootstrap "/usr/local/bin/oneexit link" "${link}" "/usr/local/share/oneexit/${pinned}/client/oneexit"
  resolved="$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' /usr/local/bin/oneexit)"
  target="$(cd -P "/usr/local/share/oneexit/${pinned}/client" 2>/dev/null && pwd)/oneexit"
  expect_eq bootstrap "symlink chain resolves" "${resolved}" "${target}"
  if [ -x "${resolved}" ] && [ -f "/usr/local/share/oneexit/${pinned}/client/lib/common.sh" ]; then
    record bootstrap "installed copy complete" PASS "client/oneexit executable, client/lib present" "same"
  else
    record bootstrap "installed copy complete" FAIL "$(find "/usr/local/share/oneexit/${pinned}/client" -maxdepth 1 2>&1 | head -n 5 | tr '\n' ' ')" "client/oneexit + client/lib"
  fi
  expect_eq bootstrap "installed copy owner" "$(stat -f '%Su:%Sg' "/usr/local/share/oneexit/${pinned}")" "root:wheel"
  out="$(/usr/local/bin/oneexit version 2>&1)" || out="exit $?: ${out}"
  expect_eq bootstrap "oneexit version (installed)" "${out}" "oneexit ${pinned}"
  out="$(command -v oneexit || echo "<not in PATH>")"
  expect_eq bootstrap "oneexit in PATH" "${out}" "/usr/local/bin/oneexit"
  out="$("${CLI}" version 2>&1)" || out="exit $?: ${out}"
  record bootstrap "client/oneexit version (checkout)" INFO "${out}" "the commit under test"
  phase_end
}

phase_baseline() {
  # Scaffolding: the config that setup.sh writes (client/lib/setup_steps.sh,
  # setup_write_files), with placeholder server values. There is no tunnel on
  # the runner, so setup itself cannot run; with this file in place harden
  # stores TIMEZONE and REGION in it, as after a real setup, and leak checks
  # 9 and 12 have something to compare with instead of SKIPping.
  sudo mkdir -p "${ETC_DIR}"
  sudo tee "${CONFIG}" >/dev/null <<CONF
# oneexit client configuration (written by setup.sh)
# Edit VPS_IP / VPS_PORT if the server moves; oneexit-firewalld re-renders the
# pf anchor from this file within a few seconds.
VPS_IP=203.0.113.5
VPS_PORT=51820
VPS_HOST=
WG_IFACE_CONF=/usr/local/etc/wireguard/wg0.conf
PHYS_IFACES="auto"
TUNNEL_DNS=10.66.0.1
TIMEZONE=
REGION=
CONF
  sudo chmod 0644 "${CONFIG}"
  echo "--- scaffolding ${CONFIG}"
  cat "${CONFIG}"
  echo "--- runner: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), user $(id -un) ($(id -F 2>/dev/null || true))"
  echo "--- csrutil status: $(csrutil status 2>&1 || true)"
  record baseline "time zones systemsetup lists" INFO "$(sudo systemsetup -listtimezones 2>/dev/null | tr -d ' ' | grep -E -x 'UTC|GMT|Etc/UTC|Etc/GMT' | paste -s -d ' ' - || true)" "-"
  enable_location
  snapshot baseline
  locationd_log baseline >"${OUT}/locationd-status-baseline.txt"
  if [ "$(value baseline PRIVACY_STATE)" = "<absent>" ]; then
    record baseline "no privacy-state before harden" PASS "<absent>" "<absent>"
  else
    record baseline "no privacy-state before harden" FAIL "present" "<absent>"
  fi
  leak_json baseline
  record baseline "leak-test exit (no tunnel)" INFO "$(cat "${OUT}/leak-test-baseline.rc")" "1 (checks 1-8 need the tunnel)"
  local check st
  for check in timezone location names region; do
    st="$(leak_status baseline "${check}")"
    record baseline "leak check ${check} (before)" INFO "${st}" "-"
  done
  phase_end
}

# assert_hardened PHASE LABEL: the values harden must have set.
assert_hardened() {
  local p="$1" l="$2" base_locale base_lang loc lang want_lang bundle entry bad=""
  expect_eq "${p}" "time zone (systemsetup)" "$(value "${l}" TIMEZONE)" "${TZ_WANT}"
  expect_eq "${p}" "/etc/localtime" "$(value "${l}" LOCALTIME)" "/var/db/timezone/zoneinfo/${TZ_WANT}"
  expect_eq "${p}" "automatic time zone" "$(value "${l}" TZ_AUTO)" "0"
  expect_eq "${p}" "Location Services (privacy.sh path)" "$(value "${l}" LOCATION)" "0"
  expect_eq "${p}" "Location Services (-currentHost)" "$(value "${l}" LOCATION_CURRENTHOST)" "0"
  record "${p}" "Location Services (notbackedup)" INFO "$(value "${l}" LOCATION_NOTBACKEDUP)" "-"
  case "$(value "${l}" LOCATION_API)" in
    false) record "${p}" "Location Services (CoreLocation)" PASS "false" "false" ;;
    true) record "${p}" "Location Services (CoreLocation)" FAIL "true" "false" ;;
    *) record "${p}" "Location Services (CoreLocation)" INFO "unknown" "false" ;;
  esac
  expect_eq "${p}" "ComputerName" "$(value "${l}" COMPUTER_NAME)" "${GENERIC_NAME}"
  expect_eq "${p}" "HostName" "$(value "${l}" HOST_NAME)" "${GENERIC_NAME}"
  expect_eq "${p}" "LocalHostName" "$(value "${l}" LOCAL_HOST_NAME)" "${GENERIC_NAME}"
  loc="$(value "${l}" APPLE_LOCALE)"
  base_locale="$(value baseline APPLE_LOCALE)"
  base_lang="$(value baseline APPLE_LANGUAGES)"
  # The language part stays: from the old AppleLocale, or (when there was
  # none) from the first AppleLanguages entry without its region.
  if [ "${base_locale}" != "<absent>" ]; then
    want_lang="${base_locale%%@*}"
    want_lang="${want_lang%%_*}"
  else
    want_lang="${base_lang%%;*}"
    want_lang="${want_lang%%-*}"
    [ "${want_lang}" != "<absent>" ] || want_lang="en"
  fi
  expect_eq "${p}" "AppleLocale" "${loc}" "${want_lang}_${REGION_WANT}"
  lang="$(value "${l}" APPLE_LANGUAGES)"
  for entry in $(printf '%s\n' "${lang}" | tr ';' ' '); do
    case "${entry##*-}" in
      "${entry}" | "${REGION_WANT}") ;;
      [A-Z][A-Z] | [0-9][0-9][0-9]) bad="${bad} ${entry}" ;;
      *) ;;
    esac
  done
  if [ -z "${bad}" ] && [ "$(printf '%s\n' "${lang}" | cut -d';' -f1 | cut -d- -f1)" = "$(printf '%s\n' "${base_lang}" | cut -d';' -f1 | cut -d- -f1)" ]; then
    record "${p}" "AppleLanguages (language kept)" PASS "${lang}" "${base_lang} without a foreign region"
  else
    record "${p}" "AppleLanguages (language kept)" FAIL "${lang}" "${base_lang} without a foreign region"
  fi
  for bundle in ${CHROME_BUNDLES}; do
    expect_eq "${p}" "WebRTC ${bundle}" "$(value "${l}" "WEBRTC_${bundle}")" "${WEBRTC_WANT}"
  done
  if [ "$(value baseline FIREFOX_INSTALLED)" = "yes" ] && [ "$(value baseline FIREFOX_POLICY)" = "<absent>" ]; then
    if sudo grep -q 'media.peerconnection.ice.default_address_only' "${FIREFOX_POLICY}" 2>/dev/null; then
      record "${p}" "Firefox policies.json" PASS "sets default_address_only" "sets default_address_only"
    else
      record "${p}" "Firefox policies.json" FAIL "$(value "${l}" FIREFOX_POLICY)" "sets default_address_only"
    fi
  else
    record "${p}" "Firefox policies.json" INFO "installed=$(value baseline FIREFOX_INSTALLED), policy before=$(value baseline FIREFOX_POLICY)" "left alone"
  fi
  expect_eq "${p}" "Lookup suggestions disabled" "$(value "${l}" LOOKUP_SUGGESTIONS_DISABLED)" "1"
  if [ "$(value "${l}" SAFARI_UNIVERSAL_SEARCH)" = "0" ]; then
    record "${p}" "Safari suggestions (optional)" PASS "0" "0"
  else
    record "${p}" "Safari suggestions (optional)" INFO "$(value "${l}" SAFARI_UNIVERSAL_SEARCH)" "0 (sandboxed, may need Full Disk Access)"
  fi
  expect_eq "${p}" "privacy-state present" "$(value "${l}" PRIVACY_STATE)" "present"
}

phase_harden() {
  local rc mo st check reason
  rc="$(run_cli harden-1.log harden --timezone "${TZ_WANT}" --region "${REGION_WANT}")"
  expect_eq harden "harden exit code" "${rc}" 0
  if grep -q 'could not restart locationd' "${OUT}/harden-1.log"; then
    record harden "locationd kickstart" INFO "could not restart locationd" "restarted"
  else
    record harden "locationd kickstart" INFO "no warning" "restarted"
  fi
  if grep -q 'not found; TIMEZONE and REGION are not stored' "${OUT}/harden-1.log"; then
    record harden "config warning" FAIL "config not found warning" "no warning (scaffolding config present)"
  fi
  sleep 3
  snapshot hardened
  expect_eq harden "locationd logged at start" "$(locationd_log hardened)" "0"
  record harden "locationd pid" INFO "$(value baseline LOCATIOND_PID) -> $(value hardened LOCATIOND_PID)" "a new pid after kickstart -k"
  assert_hardened harden hardened
  mo="$(sudo stat -f '%Lp %Su' "${STATE}" 2>/dev/null || echo "?")"
  expect_eq harden "privacy-state mode/owner" "${mo}" "600 root"
  sudo cat "${STATE}" >"${OUT}/privacy-state-1.txt" 2>/dev/null || true
  echo "--- ${STATE}"
  cat "${OUT}/privacy-state-1.txt"
  expect_eq harden "config TIMEZONE" "$(sed -n 's/^TIMEZONE=//p' "${CONFIG}" | tail -n 1)" "${TZ_WANT}"
  expect_eq harden "config REGION" "$(sed -n 's/^REGION=//p' "${CONFIG}" | tail -n 1)" "${REGION_WANT}"
  expect_eq harden "config TIMEZONE lines" "$(grep -c '^TIMEZONE=' "${CONFIG}")" "1"
  expect_eq harden "config keeps VPS_IP" "$(sed -n 's/^VPS_IP=//p' "${CONFIG}")" "203.0.113.5"
  rc="$(run_cli status-hardened.log status)"
  expect_eq harden "status exit code" "${rc}" 0
  expect_eq harden "status privacy line" "$(privacy_line status-hardened.log)" "hardened"
  run_cli doctor-hardened.log doctor >/dev/null || true
  leak_json hardened
  record harden "leak-test exit (no tunnel)" INFO "$(cat "${OUT}/leak-test-hardened.rc")" "1 (checks 1-8 need the tunnel)"
  if python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "${OUT}/leak-test-hardened.json" 2>/dev/null; then
    record harden "leak-test JSON parses" PASS "valid JSON, $(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "${OUT}/leak-test-hardened.json") checks" "valid JSON, 12 checks"
  else
    record harden "leak-test JSON parses" FAIL "invalid JSON" "valid JSON"
  fi
  for check in timezone location names region; do
    st="$(leak_status hardened "${check}")"
    reason="${st#*	}"
    st="${st%%	*}"
    if [ "${st}" = "PASS" ]; then
      record harden "leak check ${check}" PASS "PASS: ${reason}" "PASS"
    else
      record harden "leak check ${check}" FAIL "${st}: ${reason}" "PASS"
    fi
  done
  phase_end
}

# assert_restored PHASE LABEL: every value is back to the baseline.
assert_restored() {
  local p="$1" l="$2" key
  for key in ${RESTORE_KEYS}; do
    expect_eq "${p}" "restored ${key}" "$(value "${l}" "${key}")" "$(value baseline "${key}")"
  done
  expect_eq "${p}" "privacy-state removed" "$(value "${l}" PRIVACY_STATE)" "<absent>"
}

phase_unharden() {
  local rc
  rc="$(run_cli unharden-1.log unharden)"
  expect_eq unharden "unharden exit code" "${rc}" 0
  sleep 3
  snapshot restored
  expect_eq unharden "locationd logged at start" "$(locationd_log restored)" "$(cat "${OUT}/locationd-status-baseline.txt")"
  assert_restored unharden restored
  rc="$(run_cli status-restored.log status)"
  expect_eq unharden "status exit code" "${rc}" 0
  expect_eq unharden "status privacy line" "$(privacy_line status-restored.log)" "off"
  phase_end
}

phase_idempotence() {
  local rc key
  # Second harden: no options, so TIMEZONE and REGION come from the config
  # that the first harden wrote.
  rc="$(run_cli harden-2.log harden)"
  expect_eq idempotence "harden (from config) exit code" "${rc}" 0
  sudo cat "${STATE}" >"${OUT}/privacy-state-2.txt" 2>/dev/null || true
  # The state file of this round records the baseline again, not hardened values.
  expect_eq idempotence "state TIMEZONE" "$(sed -n 's/^TIMEZONE=//p' "${OUT}/privacy-state-2.txt")" "$(value baseline TIMEZONE)"
  expect_eq idempotence "state COMPUTER_NAME" "$(sed -n 's/^COMPUTER_NAME=//p' "${OUT}/privacy-state-2.txt")" "$(sed -n 's/^COMPUTER_NAME=//p' "${OUT}/privacy-state-1.txt")"
  # Third harden on top of a hardened Mac: the state file must not change.
  rc="$(run_cli harden-3.log harden --timezone "${TZ_WANT}" --region "${REGION_WANT}")"
  expect_eq idempotence "harden again exit code" "${rc}" 0
  sudo cat "${STATE}" >"${OUT}/privacy-state-3.txt" 2>/dev/null || true
  if cmp -s "${OUT}/privacy-state-2.txt" "${OUT}/privacy-state-3.txt"; then
    record idempotence "state file unchanged by harden again" PASS "identical" "identical"
  else
    record idempotence "state file unchanged by harden again" FAIL "$(diff "${OUT}/privacy-state-2.txt" "${OUT}/privacy-state-3.txt" | tr '\n' ' ')" "identical"
  fi
  if grep -q 'keeping .*privacy-state' "${OUT}/harden-3.log"; then
    record idempotence "harden again says it keeps the state" PASS "keeping ${STATE}" "keeping ${STATE}"
  else
    record idempotence "harden again says it keeps the state" FAIL "no 'keeping' line" "keeping ${STATE}"
  fi
  for key in TIMEZONE TZ_AUTO LOCATION COMPUTER_NAME HOST_NAME LOCAL_HOST_NAME APPLE_LOCALE APPLE_LANGUAGES; do
    expect_eq idempotence "state ${key} = round 1" \
      "$(sed -n "s/^${key}=//p" "${OUT}/privacy-state-3.txt")" "$(sed -n "s/^${key}=//p" "${OUT}/privacy-state-1.txt")"
  done
  sleep 3
  snapshot hardened-2
  assert_hardened idempotence hardened-2
  rc="$(run_cli unharden-2.log unharden)"
  expect_eq idempotence "unharden exit code" "${rc}" 0
  sleep 3
  snapshot restored-2
  assert_restored idempotence restored-2
  rc="$(run_cli unharden-3.log unharden)"
  expect_eq idempotence "unharden with nothing to do" "${rc}" 0
  phase_end
}

# probe_timezone_names: after everything else, what systemsetup does with the
# UTC and GMT names (it reports the UTC zone as GMT).
probe_timezone_names() {
  local tz out
  for tz in UTC GMT; do
    out="$(sudo systemsetup -settimezone "${tz}" 2>&1 || echo "(exit $?)")"
    out="$(printf '%s\n' "${out}" | grep -v 'Error:-99' | tr '\n' ' ' || true)"
    record probe "systemsetup -settimezone ${tz}" INFO "${out}-> link $(readlink /etc/localtime), get: $(timezone_now), date +%Z: $(date +%Z)" "-"
  done
}

phase_summary() {
  local key md="${OUT}/summary.md" total pass fail info
  probe_timezone_names
  # Remove the scaffolding config (and the directory if nothing else is left).
  sudo rm -f "${CONFIG}"
  sudo rmdir "${ETC_DIR}" 2>/dev/null || true
  total="$(wc -l <"${RESULTS}" | tr -d ' ')"
  pass="$(awk -F'\t' '$3 == "PASS"' "${RESULTS}" | wc -l | tr -d ' ')"
  fail="$(awk -F'\t' '$3 == "FAIL"' "${RESULTS}" | wc -l | tr -d ' ')"
  info="$(awk -F'\t' '$3 == "INFO"' "${RESULTS}" | wc -l | tr -d ' ')"
  {
    echo "## macOS real run: ${pass} PASS, ${fail} FAIL, ${info} INFO (${total} checks)"
    echo
    echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), commit ${GITHUB_SHA:-unknown}"
    echo
    echo "### Values"
    echo
    echo "| Key | Baseline | After harden | Restored | After harden x2 | Restored again |"
    echo "|---|---|---|---|---|---|"
    for key in ${RESTORE_KEYS} FIREFOX_INSTALLED PRIVACY_STATE LOCATIOND_PID; do
      printf '| %s | %s | %s | %s | %s | %s |\n' "${key}" \
        "$(cell baseline "${key}")" "$(cell hardened "${key}")" "$(cell restored "${key}")" \
        "$(cell hardened-2 "${key}")" "$(cell restored-2 "${key}")"
    done
    echo
    echo "### Checks"
    echo
    echo "| Phase | Check | Result | Observed | Expected |"
    echo "|---|---|---|---|---|"
    awk -F'\t' '{ gsub(/\|/, "/"); printf "| %s | %s | %s | `%s` | `%s` |\n", $1, $2, $3, $4, $5 }' "${RESULTS}"
  } >"${md}"
  cat "${md}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "${md}" >>"${GITHUB_STEP_SUMMARY}"
  fi
  [ "${fail}" -eq 0 ]
}

cell() {
  local v
  if [ -r "${OUT}/$1.env" ]; then
    v="$(value "$1" "$2" | tr '|' '/')"
    # shellcheck disable=SC2016 # backticks are Markdown code spans
    printf '`%s`' "${v:--}"
  else
    printf '%s' "-"
  fi
}

guard
case "${1:-}" in
  bootstrap) phase_bootstrap ;;
  baseline) phase_baseline ;;
  harden) phase_harden ;;
  unharden) phase_unharden ;;
  idempotence) phase_idempotence ;;
  summary) phase_summary ;;
  *)
    echo "usage: $0 bootstrap|baseline|harden|unharden|idempotence|summary" >&2
    exit 2
    ;;
esac
