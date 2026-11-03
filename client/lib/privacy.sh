# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# oneexit client: environment hardening. The tunnel hides where the Mac
# connects from; these settings keep macOS from telling apps where it is:
# Location Services, the automatic time zone, the region in the locale, the
# computer name that DHCP announces, and the LAN address WebRTC offers.
#
# Layout: pure functions (arguments in, stdout out, no files touched), then
# read-only probes of the live settings, then harden_apply / unharden_apply,
# which change the system only through run() and write_file() so that
# --dry-run prints every command. Needs common.sh. Stock bash 3.2 compatible.

ONEEXIT_PRIVACY_STATE="${ONEEXIT_PRIVACY_STATE:-${ONEEXIT_ETC_DIR}/privacy-state}"
ONEEXIT_ZONEINFO="${ONEEXIT_ZONEINFO:-/usr/share/zoneinfo}"
ONEEXIT_APPLICATIONS_DIR="${ONEEXIT_APPLICATIONS_DIR:-/Applications}"
ONEEXIT_LOCALTIME="${ONEEXIT_LOCALTIME:-/etc/localtime}"
# Where /etc/localtime points (systemsetup links it into this directory).
ONEEXIT_TZ_LINK_DIR="${ONEEXIT_TZ_LINK_DIR:-/var/db/timezone/zoneinfo}"

PRIVACY_DEFAULT_TIMEZONE="Europe/Berlin"
PRIVACY_DEFAULT_REGION="DE"
PRIVACY_GENERIC_NAME="Mac"
PRIVACY_NAME_KEYS="ComputerName HostName LocalHostName"
PRIVACY_LOCATIOND_DOMAIN="/var/db/locationd/Library/Preferences/ByHost/com.apple.locationd"
PRIVACY_LOCATIOND_SERVICE="system/com.apple.locationd"
PRIVACY_TZAUTO_DOMAIN="/Library/Preferences/com.apple.timezone.auto"
PRIVACY_SYSTEM_PREFS="/Library/Preferences"
PRIVACY_CHROME_BUNDLES="com.google.Chrome com.brave.Browser com.microsoft.Edge org.chromium.Chromium"
PRIVACY_WEBRTC_POLICY="disable_non_proxied_udp"
PRIVACY_FIREFOX_PREF="media.peerconnection.ice.default_address_only"
PRIVACY_LOOKUP_DOMAIN="com.apple.lookup.shared"
PRIVACY_SAFARI_DOMAIN="com.apple.Safari"

# Settings that could not be changed by the last harden_apply/unharden_apply.
PRIVACY_FAILED=0

# ---------------------------------------------------------------- pure functions

# tz_is_valid TZ: 0 if TZ names a zone file under ONEEXIT_ZONEINFO
# (Europe/Berlin, UTC, Etc/GMT+3). Rejects paths, dots and spaces.
tz_is_valid() {
  local tz="$1"
  case "${tz}" in
    '' | /* | *..* | *[!A-Za-z0-9_+/-]*) return 1 ;;
    *) ;;
  esac
  [ -f "${ONEEXIT_ZONEINFO}/${tz}" ]
}

# region_normalize RR: upper-case a region code (de -> DE).
region_normalize() {
  printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'
}

# region_is_valid RR: two upper-case letters (ISO 3166-1 alpha-2).
region_is_valid() {
  case "$1" in
    [[:upper:]][[:upper:]]) return 0 ;;
    *) return 1 ;;
  esac
}

# region_from_timezone TZ: the country of a European zone, or nothing.
region_from_timezone() {
  case "$1" in
    Europe/Berlin) echo DE ;;
    Europe/Paris) echo FR ;;
    Europe/Amsterdam) echo NL ;;
    Europe/Helsinki) echo FI ;;
    Europe/Stockholm) echo SE ;;
    Europe/Vienna) echo AT ;;
    Europe/Zurich) echo CH ;;
    Europe/Madrid) echo ES ;;
    Europe/Rome) echo IT ;;
    Europe/Warsaw) echo PL ;;
    Europe/Prague) echo CZ ;;
    Europe/London) echo GB ;;
    Europe/Dublin) echo IE ;;
    Europe/Lisbon) echo PT ;;
    Europe/Oslo) echo NO ;;
    Europe/Copenhagen) echo DK ;;
    Europe/Brussels) echo BE ;;
    Europe/Luxembourg) echo LU ;;
    Europe/Riga) echo LV ;;
    Europe/Vilnius) echo LT ;;
    Europe/Tallinn) echo EE ;;
    *) ;;
  esac
}

# locale_with_region LOCALE REGION: keep the language (and script), replace
# the region: ru_KZ -> ru_DE, en -> en_DE, zh-Hans_CN -> zh-Hans_DE.
# "@key=value;..." qualifiers are stripped and re-appended, except rg=
# (region override) and currency=, which name a country themselves.
# An empty LOCALE gives en_REGION.
locale_with_region() {
  local loc="$1" region="$2" qual="" lang item kept="" rest
  case "${loc}" in
    *@*)
      qual="${loc#*@}"
      loc="${loc%%@*}"
      ;;
    *) ;;
  esac
  lang="${loc%%_*}"
  [ -n "${lang}" ] || lang="en"
  rest="${qual}"
  while [ -n "${rest}" ]; do
    item="${rest%%;*}"
    case "${rest}" in
      *';'*) rest="${rest#*;}" ;;
      *) rest="" ;;
    esac
    case "${item}" in
      '' | rg=* | currency=*) ;;
      *) kept="${kept}${kept:+;}${item}" ;;
    esac
  done
  if [ -n "${kept}" ]; then
    printf '%s_%s@%s\n' "${lang}" "${region}" "${kept}"
  else
    printf '%s_%s\n' "${lang}" "${region}"
  fi
}

# locale_region LOCALE: the region part of an AppleLocale (ru_KZ@x=y -> KZ).
locale_region() {
  local loc="${1%%@*}"
  case "${loc}" in
    *_*) ;;
    *) return 0 ;;
  esac
  loc="${loc#*_}"
  printf '%s\n' "${loc%%_*}"
}

# languages_parse: AppleLanguages as "defaults read" prints it (or one entry
# per line) on stdin; one bare entry per line on stdout.
languages_parse() {
  sed -e 's/[[:space:]]//g' -e 's/"//g' -e 's/,$//' | grep -v -e '^($' -e '^)$' -e '^$' || true
}

# languages_strip_region REGION: AppleLanguages on stdin (array lines or one
# entry per line). Entries lose a region that is not REGION (ru-KZ -> ru,
# zh-Hans-CN -> zh-Hans, es-419 -> es); order is kept, duplicates dropped.
languages_strip_region() {
  local region="$1" entry last
  languages_parse | while IFS= read -r entry; do
    last="${entry##*-}"
    if [ "${last}" != "${entry}" ] && [ "${last}" != "${region}" ]; then
      case "${last}" in
        [[:upper:]][[:upper:]] | [0-9][0-9][0-9]) entry="${entry%-*}" ;;
        *) ;;
      esac
    fi
    printf '%s\n' "${entry}"
  done | awk '!seen[$0]++'
}

# privacy_peer_timezone FILE: the "# oneexit-timezone = TZ" comment that
# server/peer.sh writes into peer configs (wg-quick ignores it).
privacy_peer_timezone() {
  [ -r "$1" ] || return 1
  sed -n 's/^[[:space:]]*#[[:space:]]*oneexit-timezone[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*$/\1/p' "$1" |
    head -n 1
}

# render_firefox_policies: Firefox enterprise policy that keeps WebRTC to the
# default route's address (the tunnel), so sites do not see the LAN address.
render_firefox_policies() {
  cat <<JSON
{
  "policies": {
    "Preferences": {
      "${PRIVACY_FIREFOX_PREF}": {
        "Value": true,
        "Status": "locked"
      }
    }
  }
}
JSON
}

# _kv_value FILE KEY: value of the first KEY=value line (the rest of the line
# after the first "=", so values may contain "=" and spaces).
_kv_value() {
  local file="$1" want="$2" line
  [ -r "${file}" ] || return 1
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      "${want}="*)
        printf '%s\n' "${line#*=}"
        return 0
        ;;
      *) ;;
    esac
  done <"${file}"
  return 1
}

# privacy_config_value KEY [FILE]: TIMEZONE / REGION from the oneexit config.
privacy_config_value() {
  local value
  value="$(_kv_value "${2:-${ONEEXIT_CONFIG}}" "$1")" || return 1
  value="${value%\"}"
  printf '%s\n' "${value#\"}"
}

# privacy_state_read KEY: a value recorded by the first harden.
privacy_state_read() {
  _kv_value "${ONEEXIT_PRIVACY_STATE}" "$1"
}

_bool_word() {
  case "$1" in
    0 | false | FALSE | NO | no) echo false ;;
    *) echo true ;;
  esac
}

_webrtc_label() {
  case "$1" in
    com.google.Chrome) echo "Chrome WebRTC" ;;
    com.brave.Browser) echo "Brave WebRTC" ;;
    com.microsoft.Edge) echo "Edge WebRTC" ;;
    org.chromium.Chromium) echo "Chromium WebRTC" ;;
    *) echo "$1 WebRTC" ;;
  esac
}

# ---------------------------------------------------------------- read-only probes

# privacy_user: the account whose user defaults (locale, Lookup, Safari) are
# read and changed: ONEEXIT_PRIVACY_USER, the user who called sudo, the
# current user, or the owner of the console when running as plain root.
privacy_user() {
  local user=""
  if [ -n "${ONEEXIT_PRIVACY_USER:-}" ]; then
    user="${ONEEXIT_PRIVACY_USER}"
  elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    user="${SUDO_USER}"
  elif ! is_root; then
    user="$(id -un 2>/dev/null || true)"
  else
    user="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
  fi
  printf '%s\n' "${user:-root}"
}

# privacy_full_name USER: the account's full name (id -F), or nothing.
privacy_full_name() {
  id -F "$1" 2>/dev/null || true
}

# _needs_sudo_u USER: 0 if reading or writing USER's defaults from this
# process has to go through "sudo -u USER".
_needs_sudo_u() {
  [ "$1" != "root" ] && is_root && [ "$1" != "$(id -un 2>/dev/null || true)" ]
}

privacy_defaults_read() {
  defaults read "$@" 2>/dev/null | head -n 1
}

# privacy_user_defaults_read USER ARGS...: "defaults read ARGS" as USER.
privacy_user_defaults_read() {
  local user="$1"
  shift
  if _needs_sudo_u "${user}"; then
    sudo -u "${user}" -H defaults read "$@" 2>/dev/null
  else
    defaults read "$@" 2>/dev/null
  fi
}

# privacy_timezone_now: the system time zone, from the /etc/localtime link
# (the zone libc uses). systemsetup -gettimezone is only the fallback: it
# needs root and reports some zones under another name (UTC as "GMT"), and
# restoring that name would switch the Mac to a different zone.
privacy_timezone_now() {
  local tz="" link
  link="$(readlink "${ONEEXIT_LOCALTIME}" 2>/dev/null || true)"
  case "${link}" in
    *zoneinfo/*) tz="${link##*zoneinfo/}" ;;
    *) ;;
  esac
  if [ -z "${tz}" ] && is_root && command -v systemsetup >/dev/null 2>&1; then
    tz="$(systemsetup -gettimezone 2>/dev/null | sed -n 's/^Time Zone: //p' | head -n 1)" || tz=""
  fi
  printf '%s\n' "${tz}"
}

privacy_location_now() { privacy_defaults_read "${PRIVACY_LOCATIOND_DOMAIN}" LocationServicesEnabled || true; }
privacy_tz_auto_now() { privacy_defaults_read "${PRIVACY_TZAUTO_DOMAIN}" Active || true; }
privacy_locale_now() { privacy_user_defaults_read "$1" -g AppleLocale | head -n 1 || true; }
privacy_lookup_now() { privacy_user_defaults_read "$1" "${PRIVACY_LOOKUP_DOMAIN}" LookupSuggestionsDisabled | head -n 1 || true; }
privacy_safari_now() { privacy_user_defaults_read "$1" "${PRIVACY_SAFARI_DOMAIN}" UniversalSearchEnabled | head -n 1 || true; }

# privacy_languages_now USER: AppleLanguages joined with ";" (ru-KZ;en-US).
privacy_languages_now() {
  privacy_user_defaults_read "$1" -g AppleLanguages | languages_parse | paste -s -d ';' - || true
}

# privacy_name_now ComputerName|HostName|LocalHostName: empty when not set
# (scutil then says "HostName: not set" and exits 1).
privacy_name_now() {
  local name
  name="$(scutil --get "$1" 2>/dev/null)" || name=""
  printf '%s\n' "${name}" | head -n 1
}

privacy_webrtc_now() {
  privacy_defaults_read "${PRIVACY_SYSTEM_PREFS}/$1" WebRtcIPHandlingPolicy || true
}

privacy_firefox_app() { printf '%s\n' "${ONEEXIT_APPLICATIONS_DIR}/Firefox.app"; }
privacy_firefox_policy() { printf '%s\n' "$(privacy_firefox_app)/Contents/Resources/distribution/policies.json"; }

# privacy_capture USER: the current values, as the KEY=value lines of the
# state file. An empty value means "not set" (unharden deletes it again).
privacy_capture() {
  local user="$1" bundle value created=no
  printf '# Written by oneexit harden before it changed anything; read by oneexit unharden.\n'
  printf '# An empty value means the setting was not set; unharden removes it again.\n'
  printf 'HARDEN_EPOCH=%s\n' "$(now_epoch)"
  printf 'USER=%s\n' "${user}"
  printf 'LOCATION_SERVICES=%s\n' "$(privacy_location_now)"
  printf 'TZ_AUTO=%s\n' "$(privacy_tz_auto_now)"
  printf 'TIMEZONE=%s\n' "$(privacy_timezone_now)"
  printf 'APPLE_LOCALE=%s\n' "$(privacy_locale_now "${user}")"
  printf 'APPLE_LANGUAGES=%s\n' "$(privacy_languages_now "${user}")"
  printf 'COMPUTER_NAME=%s\n' "$(privacy_name_now ComputerName)"
  printf 'HOST_NAME=%s\n' "$(privacy_name_now HostName)"
  printf 'LOCAL_HOST_NAME=%s\n' "$(privacy_name_now LocalHostName)"
  for bundle in ${PRIVACY_CHROME_BUNDLES}; do
    value="$(privacy_webrtc_now "${bundle}")"
    if [ -n "${value}" ]; then
      printf 'CHROME_WEBRTC_%s=present:%s\n' "${bundle}" "${value}"
    else
      printf 'CHROME_WEBRTC_%s=absent\n' "${bundle}"
    fi
  done
  if [ -d "$(privacy_firefox_app)" ] && [ ! -e "$(privacy_firefox_policy)" ]; then
    created=yes
  fi
  printf 'FIREFOX_POLICY_CREATED=%s\n' "${created}"
  printf 'LOOKUP_SUGGESTIONS=%s\n' "$(privacy_lookup_now "${user}")"
  printf 'SAFARI_UNIVERSAL_SEARCH=%s\n' "$(privacy_safari_now "${user}")"
}

# privacy_state_write USER: record the current values, once. A second harden
# keeps the file, so unharden always goes back to the values from before the
# first one.
privacy_state_write() {
  if [ -e "${ONEEXIT_PRIVACY_STATE}" ]; then
    log_ok "keeping ${ONEEXIT_PRIVACY_STATE} (the values from before the first harden)"
    return 0
  fi
  if ! is_root; then
    log_info "    (not root: values that need root to read, like Location Services, show as empty)"
  fi
  run mkdir -p "$(dirname "${ONEEXIT_PRIVACY_STATE}")"
  privacy_capture "$1" | write_file "${ONEEXIT_PRIVACY_STATE}" 0600
}

# privacy_report [TZ] [REGION] [USER]: one line per setting,
#   NAME|ok,bad,na|CURRENT|EXPECTED|core,extra
# "core" settings decide privacy_status. Safari is "extra": its preferences
# live in a sandbox container that a plain "defaults read" may not see.
privacy_report() {
  local tz="${1:-}" region="${2:-}" user="${3:-}" v res key label bundle stripped
  [ -n "${tz}" ] || tz="$(privacy_config_value TIMEZONE 2>/dev/null || true)"
  [ -n "${region}" ] || region="$(privacy_config_value REGION 2>/dev/null || true)"
  [ -n "${user}" ] || user="$(privacy_user)"

  v="$(privacy_location_now)"
  case "${v}" in
    0) printf 'location|ok|off (0)|off (0)|core\n' ;;
    1) printf 'location|bad|on (1)|off (0)|core\n' ;;
    '')
      if is_root; then
        printf 'location|bad|not set|off (0)|core\n'
      else
        printf 'location|na|unknown (needs sudo)|off (0)|core\n'
      fi
      ;;
    *) printf 'location|bad|%s|off (0)|core\n' "${v}" ;;
  esac

  v="$(privacy_tz_auto_now)"
  case "${v}" in
    0) printf 'auto time zone|ok|off|off|core\n' ;;
    '') printf 'auto time zone|bad|not set (on)|off|core\n' ;;
    *) printf 'auto time zone|bad|on|off|core\n' ;;
  esac

  v="$(privacy_timezone_now)"
  if [ -z "${tz}" ]; then
    printf 'time zone|na|%s|(no TIMEZONE in config)|core\n' "${v:-unknown}"
  elif [ "${v}" = "${tz}" ]; then
    printf 'time zone|ok|%s|%s|core\n' "${v}" "${tz}"
  else
    printf 'time zone|bad|%s|%s|core\n' "${v:-unknown}" "${tz}"
  fi

  v="$(privacy_locale_now "${user}")"
  if [ -z "${region}" ]; then
    printf 'region|na|%s|(no REGION in config)|core\n' "${v:-not set}"
  elif [ -n "${v}" ] && [ "$(locale_region "${v}")" = "${region}" ]; then
    printf 'region|ok|%s|*_%s|core\n' "${v}" "${region}"
  else
    printf 'region|bad|%s|*_%s|core\n' "${v:-not set}" "${region}"
  fi

  v="$(privacy_languages_now "${user}")"
  if [ -z "${region}" ] || [ -z "${v}" ]; then
    printf 'languages|na|%s|no foreign region|core\n' "${v:-not set}"
  else
    stripped="$(printf '%s\n' "${v}" | tr ';' '\n' | languages_strip_region "${region}" | paste -s -d ';' -)"
    if [ "${stripped}" = "${v}" ]; then
      printf 'languages|ok|%s|no foreign region|core\n' "${v}"
    else
      printf 'languages|bad|%s|%s|core\n' "${v}" "${stripped}"
    fi
  fi

  for key in ${PRIVACY_NAME_KEYS}; do
    case "${key}" in
      ComputerName) label="computer name" ;;
      HostName) label="host name" ;;
      *) label="local host name" ;;
    esac
    v="$(privacy_name_now "${key}" | tr '|' '/')"
    if [ "${v}" = "${PRIVACY_GENERIC_NAME}" ]; then res=ok; else res=bad; fi
    printf '%s|%s|%s|%s|core\n' "${label}" "${res}" "${v:-not set}" "${PRIVACY_GENERIC_NAME}"
  done

  for bundle in ${PRIVACY_CHROME_BUNDLES}; do
    v="$(privacy_webrtc_now "${bundle}")"
    if [ "${v}" = "${PRIVACY_WEBRTC_POLICY}" ]; then res=ok; else res=bad; fi
    printf '%s|%s|%s|%s|core\n' "$(_webrtc_label "${bundle}")" "${res}" "${v:-not set}" "${PRIVACY_WEBRTC_POLICY}"
  done

  if [ ! -d "$(privacy_firefox_app)" ]; then
    printf 'Firefox WebRTC|na|Firefox not installed|%s|core\n' "${PRIVACY_FIREFOX_PREF}"
  elif grep -q "${PRIVACY_FIREFOX_PREF}" "$(privacy_firefox_policy)" 2>/dev/null; then
    printf 'Firefox WebRTC|ok|policies.json sets it|%s|core\n' "${PRIVACY_FIREFOX_PREF}"
  else
    printf 'Firefox WebRTC|bad|not in policies.json|%s|core\n' "${PRIVACY_FIREFOX_PREF}"
  fi

  # LookupSuggestionsDisabled: 1 is off. UniversalSearchEnabled: 0 is off.
  v="$(privacy_lookup_now "${user}")"
  case "${v}" in
    1) printf 'Lookup suggest.|ok|off|off|core\n' ;;
    0) printf 'Lookup suggest.|bad|on|off|core\n' ;;
    *) printf 'Lookup suggest.|bad|%s|off|core\n' "${v:-not set (on)}" ;;
  esac

  v="$(privacy_safari_now "${user}")"
  case "${v}" in
    0) printf 'Safari suggest.|ok|off|off|extra\n' ;;
    1) printf 'Safari suggest.|bad|on|off|extra\n' ;;
    *) printf 'Safari suggest.|bad|%s|off|extra\n' "${v:-not set (on)}" ;;
  esac
}

# privacy_status [TZ] [REGION] [USER]: hardened, partial or off, from the
# live values of the core settings (settings that cannot be read are left
# out). Without a privacy-state file anything short of hardened is "off".
privacy_status() {
  local name res cur exp scope ok=0 bad=0
  while IFS='|' read -r name res cur exp scope; do
    [ "${scope}" = "core" ] || continue
    case "${res}" in
      ok) ok=$((ok + 1)) ;;
      bad) bad=$((bad + 1)) ;;
      *) ;;
    esac
  done <<EOT
$(privacy_report "$@")
EOT
  if [ "${ok}" -gt 0 ] && [ "${bad}" -eq 0 ]; then
    echo hardened
  elif [ "${ok}" -eq 0 ] || [ ! -e "${ONEEXIT_PRIVACY_STATE}" ]; then
    echo off
  else
    echo partial
  fi
}

# ---------------------------------------------------------------- changes

# privacy_try WHAT CMD...: run CMD; on failure warn and count it.
privacy_try() {
  local what="$1"
  shift
  if ! run "$@"; then
    log_warn "could not ${what}"
    PRIVACY_FAILED=$((PRIVACY_FAILED + 1))
  fi
  return 0
}

# privacy_try_user USER WHAT CMD...: privacy_try as USER. A dry run always
# shows the "sudo -u USER -H" form that the real run (as root) uses.
privacy_try_user() {
  local user="$1" what="$2"
  shift 2
  if [ "${user}" = "root" ]; then
    privacy_try "${what}" "$@"
  elif is_dry_run || _needs_sudo_u "${user}"; then
    privacy_try "${what}" sudo -u "${user}" -H "$@"
  else
    privacy_try "${what}" "$@"
  fi
}

# _privacy_soft_user USER WHAT CMD...: like privacy_try_user, but a failure
# is only a warning (Safari's sandboxed settings may need Full Disk Access).
_privacy_soft_user() {
  local before="${PRIVACY_FAILED}" what="$2"
  privacy_try_user "$@" 2>/dev/null
  if [ "${PRIVACY_FAILED}" -ne "${before}" ]; then
    PRIVACY_FAILED="${before}"
    log_warn "could not ${what}; Safari's settings may need Full Disk Access for the terminal. Optional; continuing"
  fi
  return 0
}

# privacy_set_timezone WHAT TZ: set the system time zone with systemsetup.
# systemsetup only knows the names of its -listtimezones (GMT, but not UTC:
# "UTC is not a valid timezone"); for a zone it refuses that exists in the
# zone database, link /etc/localtime the way systemsetup does and tell
# running processes (libc re-reads the zone on this notification).
privacy_set_timezone() {
  local what="$1" tz="$2"
  if run systemsetup -settimezone "${tz}"; then
    return 0
  fi
  if ! tz_is_valid "${tz}"; then
    log_warn "could not ${what}"
    PRIVACY_FAILED=$((PRIVACY_FAILED + 1))
    return 0
  fi
  log_info "    systemsetup does not know ${tz}; linking ${ONEEXIT_LOCALTIME} to ${ONEEXIT_TZ_LINK_DIR}/${tz}"
  privacy_try "${what}" ln -sfn "${ONEEXIT_TZ_LINK_DIR}/${tz}" "${ONEEXIT_LOCALTIME}"
  run notifyutil -p com.apple.system.timezone >/dev/null 2>&1 || true
  return 0
}

# privacy_config_set TZ REGION: store TIMEZONE and REGION in the config
# (for "oneexit harden" without arguments and for the leak test).
privacy_config_set() {
  local tz="$1" region="$2" content
  if [ ! -r "${ONEEXIT_CONFIG}" ]; then
    log_warn "${ONEEXIT_CONFIG} not found; TIMEZONE and REGION are not stored (run setup first)"
    return 0
  fi
  if [ "$(privacy_config_value TIMEZONE || true)" = "${tz}" ] &&
    [ "$(privacy_config_value REGION || true)" = "${region}" ]; then
    return 0
  fi
  content="$(grep -v -E '^(TIMEZONE|REGION)=' "${ONEEXIT_CONFIG}" || true)"
  printf '%s\nTIMEZONE=%s\nREGION=%s\n' "${content}" "${tz}" "${region}" |
    write_file "${ONEEXIT_CONFIG}" 0644
}

# harden_apply TZ REGION USER: record the current values (once), then change
# every setting in the contract table. Returns 1 if any setting failed.
harden_apply() {
  local tz="$1" region="$2" user="${3:-}" locale new_locale langs first key bundle policy
  local -a new_langs=()
  PRIVACY_FAILED=0
  require_root
  tz_is_valid "${tz}" || die "unknown time zone: ${tz} (no ${ONEEXIT_ZONEINFO}/${tz})"
  region_is_valid "${region}" || die "invalid region: ${region} (two letters, for example DE)"
  [ -n "${user}" ] || user="$(privacy_user)"
  if [ "${user}" = "root" ]; then
    log_warn "no login user found: the locale and Lookup settings are applied to root (run with sudo from your account)"
  fi

  log_step "Recording the current settings in ${ONEEXIT_PRIVACY_STATE}"
  privacy_state_write "${user}"

  log_step "Turning Location Services off"
  # locationd finds the Mac from nearby Wi-Fi networks; the tunnel cannot hide that.
  privacy_try "turn Location Services off" \
    defaults write "${PRIVACY_LOCATIOND_DOMAIN}" LocationServicesEnabled -int 0
  run launchctl kickstart -k "${PRIVACY_LOCATIOND_SERVICE}" ||
    log_warn "could not restart locationd; the change takes effect after the next restart"

  log_step "Setting the time zone to ${tz} (automatic time zone off)"
  privacy_try "turn the automatic time zone off" \
    defaults write "${PRIVACY_TZAUTO_DOMAIN}" Active -bool false
  privacy_set_timezone "set the time zone" "${tz}"

  log_step "Setting the region to ${region} for ${user} (the language stays)"
  locale="$(privacy_locale_now "${user}")"
  langs="$(privacy_languages_now "${user}")"
  if [ -z "${locale}" ]; then
    first="$(printf '%s\n' "${langs}" | tr ';' '\n' | head -n 1 | languages_strip_region ZZ)"
    locale="${first:-en}"
  fi
  new_locale="$(locale_with_region "${locale}" "${region}")"
  privacy_try_user "${user}" "set AppleLocale" defaults write -g AppleLocale -string "${new_locale}"
  if [ -n "${langs}" ]; then
    while IFS= read -r first; do
      [ -n "${first}" ] && new_langs+=("${first}")
    done <<EOT
$(printf '%s\n' "${langs}" | tr ';' '\n' | languages_strip_region "${region}")
EOT
    if [ "$(printf '%s;' "${new_langs[@]}")" = "${langs};" ]; then
      log_ok "AppleLanguages (${langs}) name no other region"
    else
      privacy_try_user "${user}" "set AppleLanguages" defaults write -g AppleLanguages -array "${new_langs[@]}"
    fi
  fi

  log_step "Setting a generic computer name (${PRIVACY_GENERIC_NAME})"
  # The DHCP client sends the name to every network the Mac joins.
  for key in ${PRIVACY_NAME_KEYS}; do
    privacy_try "set the ${key}" scutil --set "${key}" "${PRIVACY_GENERIC_NAME}"
  done

  log_step "Keeping the LAN address out of WebRTC"
  for bundle in ${PRIVACY_CHROME_BUNDLES}; do
    privacy_try "set WebRtcIPHandlingPolicy for ${bundle}" \
      defaults write "${PRIVACY_SYSTEM_PREFS}/${bundle}" WebRtcIPHandlingPolicy -string "${PRIVACY_WEBRTC_POLICY}"
  done
  policy="$(privacy_firefox_policy)"
  if [ ! -d "$(privacy_firefox_app)" ]; then
    log_info "    Firefox is not installed; skipping its policy"
  elif [ -e "${policy}" ]; then
    log_warn "${policy} exists; not changing it (add ${PRIVACY_FIREFOX_PREF} = true by hand)"
  else
    privacy_try "create the Firefox policy directory" mkdir -p "$(dirname "${policy}")"
    render_firefox_policies | write_file "${policy}" 0644 ||
      {
        log_warn "could not write ${policy}"
        PRIVACY_FAILED=$((PRIVACY_FAILED + 1))
      }
  fi

  log_step "Turning Lookup and Safari search suggestions off"
  privacy_try_user "${user}" "turn Lookup suggestions off" \
    defaults write "${PRIVACY_LOOKUP_DOMAIN}" LookupSuggestionsDisabled -bool true
  _privacy_soft_user "${user}" "turn Safari suggestions off" \
    defaults write "${PRIVACY_SAFARI_DOMAIN}" UniversalSearchEnabled -bool false

  if [ "${PRIVACY_FAILED}" -gt 0 ]; then
    log_warn "${PRIVACY_FAILED} setting(s) could not be changed; see the warnings above"
    return 1
  fi
  log_ok "time zone ${tz}, region ${region}, Location Services off, computer name ${PRIVACY_GENERIC_NAME}"
  return 0
}

# _privacy_delete USER DOMAIN KEY: remove KEY (USER "" = a system domain).
# A key that is already gone is not an error.
_privacy_delete() {
  local user="$1" domain="$2" key="$3"
  if [ -z "${user}" ] || [ "${user}" = "root" ]; then
    run defaults delete "${domain}" "${key}" 2>/dev/null || true
  elif is_dry_run || _needs_sudo_u "${user}"; then
    run sudo -u "${user}" -H defaults delete "${domain}" "${key}" 2>/dev/null || true
  else
    run defaults delete "${domain}" "${key}" 2>/dev/null || true
  fi
}

# _restore_default USER DOMAIN KEY TYPE VALUE: write VALUE back, or delete
# KEY when it was not set before. USER "" means a system domain (as root).
_restore_default() {
  local user="$1" domain="$2" key="$3" type="$4" value="$5"
  if [ -z "${value}" ]; then
    _privacy_delete "${user}" "${domain}" "${key}"
    return 0
  fi
  [ "${type}" != "bool" ] || value="$(_bool_word "${value}")"
  if [ -n "${user}" ]; then
    privacy_try_user "${user}" "restore ${key}" defaults write "${domain}" "${key}" "-${type}" "${value}"
  else
    privacy_try "restore ${key}" defaults write "${domain}" "${key}" "-${type}" "${value}"
  fi
}

# unharden_apply [USER]: put back every value recorded in the state file,
# then remove it. Returns 1 if any setting failed.
unharden_apply() {
  local user="${1:-}" v key name bundle policy
  local -a langs=()
  PRIVACY_FAILED=0
  require_root
  if [ ! -e "${ONEEXIT_PRIVACY_STATE}" ]; then
    log_ok "no ${ONEEXIT_PRIVACY_STATE}: nothing to restore"
    return 0
  fi
  [ -n "${user}" ] || user="$(privacy_state_read USER || true)"
  [ -n "${user}" ] || user="$(privacy_user)"

  log_step "Restoring Location Services"
  _restore_default "" "${PRIVACY_LOCATIOND_DOMAIN}" LocationServicesEnabled int \
    "$(privacy_state_read LOCATION_SERVICES || true)"
  run launchctl kickstart -k "${PRIVACY_LOCATIOND_SERVICE}" ||
    log_warn "could not restart locationd; the change takes effect after the next restart"

  log_step "Restoring the time zone"
  _restore_default "" "${PRIVACY_TZAUTO_DOMAIN}" Active bool "$(privacy_state_read TZ_AUTO || true)"
  v="$(privacy_state_read TIMEZONE || true)"
  if [ -n "${v}" ]; then
    privacy_set_timezone "restore the time zone" "${v}"
  else
    log_warn "no time zone recorded; leaving the current one"
  fi

  log_step "Restoring the locale and languages of ${user}"
  _restore_default "${user}" -g AppleLocale string "$(privacy_state_read APPLE_LOCALE || true)"
  v="$(privacy_state_read APPLE_LANGUAGES || true)"
  if [ -z "${v}" ]; then
    _privacy_delete "${user}" -g AppleLanguages
  else
    while IFS= read -r name; do
      [ -n "${name}" ] && langs+=("${name}")
    done <<EOT
$(printf '%s\n' "${v}" | tr ';' '\n')
EOT
    privacy_try_user "${user}" "restore AppleLanguages" defaults write -g AppleLanguages -array "${langs[@]}"
  fi

  log_step "Restoring the computer name"
  for key in ${PRIVACY_NAME_KEYS}; do
    case "${key}" in
      ComputerName) v="$(privacy_state_read COMPUTER_NAME || true)" ;;
      HostName) v="$(privacy_state_read HOST_NAME || true)" ;;
      *) v="$(privacy_state_read LOCAL_HOST_NAME || true)" ;;
    esac
    if [ -n "${v}" ] || [ "${key}" = "HostName" ]; then
      # An empty HostName was "not set": setting it to '' clears it again.
      privacy_try "restore the ${key}" scutil --set "${key}" "${v}"
    else
      log_warn "no ${key} recorded; leaving ${PRIVACY_GENERIC_NAME}"
    fi
  done

  log_step "Restoring the browser WebRTC settings"
  for bundle in ${PRIVACY_CHROME_BUNDLES}; do
    v="$(privacy_state_read "CHROME_WEBRTC_${bundle}" || true)"
    case "${v}" in
      absent) _privacy_delete "" "${PRIVACY_SYSTEM_PREFS}/${bundle}" WebRtcIPHandlingPolicy ;;
      present:"${PRIVACY_WEBRTC_POLICY}" | '') ;;
      present:*)
        privacy_try "restore WebRtcIPHandlingPolicy for ${bundle}" \
          defaults write "${PRIVACY_SYSTEM_PREFS}/${bundle}" WebRtcIPHandlingPolicy -string "${v#present:}"
        ;;
      *) ;;
    esac
  done
  if [ "$(privacy_state_read FIREFOX_POLICY_CREATED || true)" = "yes" ]; then
    policy="$(privacy_firefox_policy)"
    privacy_try "remove ${policy}" rm -f "${policy}"
    run rmdir "$(dirname "${policy}")" 2>/dev/null || true
  fi

  log_step "Restoring Lookup and Safari search suggestions"
  _restore_default "${user}" "${PRIVACY_LOOKUP_DOMAIN}" LookupSuggestionsDisabled bool \
    "$(privacy_state_read LOOKUP_SUGGESTIONS || true)"
  # Safari keeps its settings in a sandbox container; a failure here is
  # reported but does not keep the state file (harden may not have got in either).
  v="$(privacy_state_read SAFARI_UNIVERSAL_SEARCH || true)"
  if [ -z "${v}" ]; then
    _privacy_delete "${user}" "${PRIVACY_SAFARI_DOMAIN}" UniversalSearchEnabled
  else
    _privacy_soft_user "${user}" "restore Safari suggestions" \
      defaults write "${PRIVACY_SAFARI_DOMAIN}" UniversalSearchEnabled -bool "$(_bool_word "${v}")"
  fi

  if [ "${PRIVACY_FAILED}" -gt 0 ]; then
    log_warn "${PRIVACY_FAILED} setting(s) could not be restored; keeping ${ONEEXIT_PRIVACY_STATE}"
    return 1
  fi
  run rm -f "${ONEEXIT_PRIVACY_STATE}"
  log_ok "the settings from before oneexit harden are back"
  return 0
}
