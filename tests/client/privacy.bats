#!/usr/bin/env bats
# Privacy hardening: client/lib/privacy.sh, oneexit harden/unharden/status/
# doctor, the setup/uninstall integration and leak-test checks 9-12.
# Every system tool is a stub from fixtures/bin; nothing on the host changes.

load ../helpers/client_helpers

setup() {
  client_test_env
}

# ---------------------------------------------------------------- pure functions

@test "locale_with_region keeps the language and replaces the region" {
  load_client_libs
  [ "$(locale_with_region ru_KZ DE)" = "ru_DE" ]
  [ "$(locale_with_region en DE)" = "en_DE" ]
  [ "$(locale_with_region '' DE)" = "en_DE" ]
  [ "$(locale_with_region zh-Hans_CN NL)" = "zh-Hans_NL" ]
  [ "$(locale_with_region en_US_POSIX FR)" = "en_FR" ]
  [ "$(locale_with_region de_DE DE)" = "de_DE" ]
}

@test "locale_with_region re-appends @ qualifiers but drops rg= and currency=" {
  load_client_libs
  [ "$(locale_with_region 'ru_KZ@calendar=gregorian' DE)" = "ru_DE@calendar=gregorian" ]
  [ "$(locale_with_region 'en_KZ@rg=kzzzzz;calendar=iso8601;currency=KZT' DE)" = "en_DE@calendar=iso8601" ]
  [ "$(locale_with_region 'ru_KZ@currency=KZT' DE)" = "ru_DE" ]
  [ "$(locale_region 'ru_KZ@calendar=gregorian')" = "KZ" ]
  [ -z "$(locale_region en)" ]
}

@test "languages_strip_region reads the defaults array, keeps order and dedupes" {
  load_client_libs
  input='(
    "ru-KZ",
    "en-US",
    en,
    "en-GB",
    "de-DE",
    "zh-Hans-CN",
    "es-419",
    "zh-Hant"
)'
  run languages_strip_region DE <<<"${input}"
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | paste -s -d ' ' -)" = "ru en de-DE zh-Hans es zh-Hant" ]
}

@test "languages_strip_region takes one entry per line; empty input gives nothing" {
  load_client_libs
  [ "$(printf 'en-US\nru-KZ\n' | languages_strip_region DE | paste -s -d ';' -)" = "en;ru" ]
  [ "$(printf 'en-DE\n' | languages_strip_region DE)" = "en-DE" ]
  [ -z "$(printf '' | languages_strip_region DE)" ]
}

@test "region_from_timezone covers the European table and nothing else" {
  load_client_libs
  for pair in Europe/Berlin=DE Europe/Paris=FR Europe/Amsterdam=NL Europe/Helsinki=FI \
    Europe/Stockholm=SE Europe/Vienna=AT Europe/Zurich=CH Europe/Madrid=ES Europe/Rome=IT \
    Europe/Warsaw=PL Europe/Prague=CZ Europe/London=GB Europe/Dublin=IE Europe/Lisbon=PT \
    Europe/Oslo=NO Europe/Copenhagen=DK Europe/Brussels=BE Europe/Luxembourg=LU \
    Europe/Riga=LV Europe/Vilnius=LT Europe/Tallinn=EE; do
    [ "$(region_from_timezone "${pair%=*}")" = "${pair#*=}" ] || {
      echo "wrong: ${pair}"
      return 1
    }
  done
  [ -z "$(region_from_timezone Asia/Tokyo)" ]
  [ -z "$(region_from_timezone Europe/Moscow)" ]
  [ -z "$(region_from_timezone '')" ]
}

@test "tz_is_valid accepts zone files and rejects Mars/Olympus and paths" {
  load_client_libs
  tz_is_valid Europe/Berlin
  tz_is_valid UTC
  run tz_is_valid Mars/Olympus
  [ "${status}" -ne 0 ]
  run tz_is_valid ''
  [ "${status}" -ne 0 ]
  run tz_is_valid Europe
  [ "${status}" -ne 0 ]
  run tz_is_valid ../zoneinfo/Europe/Berlin
  [ "${status}" -ne 0 ]
  run tz_is_valid /Europe/Berlin
  [ "${status}" -ne 0 ]
  run tz_is_valid 'Europe/Berlin x'
  [ "${status}" -ne 0 ]
}

@test "region_normalize and region_is_valid accept two letters only" {
  load_client_libs
  [ "$(region_normalize de)" = "DE" ]
  region_is_valid DE
  run region_is_valid DEU
  [ "${status}" -ne 0 ]
  run region_is_valid D1
  [ "${status}" -ne 0 ]
  run region_is_valid ''
  [ "${status}" -ne 0 ]
}

@test "privacy_peer_timezone reads the server's comment; peer.conf has none" {
  load_client_libs
  [ "$(privacy_peer_timezone "${FIXTURES}/peer-tz.conf")" = "Europe/Amsterdam" ]
  [ -z "$(privacy_peer_timezone "${PEER_CONF}")" ]
}

@test "config and state values keep '=' and spaces; quotes are stripped from config" {
  load_client_libs
  printf '%s\n' 'VPS_IP=203.0.113.5' 'TIMEZONE="Europe/Berlin"' 'REGION=DE' >"${ONEEXIT_CONFIG}"
  [ "$(privacy_config_value TIMEZONE)" = "Europe/Berlin" ]
  [ "$(privacy_config_value REGION)" = "DE" ]
  run privacy_config_value MISSING
  [ "${status}" -ne 0 ]
  printf '%s\n' "COMPUTER_NAME=Test User's MacBook =1=" 'HOST_NAME=' >"${ONEEXIT_PRIVACY_STATE}"
  [ "$(privacy_state_read COMPUTER_NAME)" = "Test User's MacBook =1=" ]
  [ -z "$(privacy_state_read HOST_NAME)" ]
}

@test "privacy_user: override, then the sudo caller, then the current user" {
  load_client_libs
  [ "$(privacy_user)" = "tester" ]
  unset ONEEXIT_PRIVACY_USER
  [ "$(SUDO_USER=alice privacy_user)" = "alice" ]
  [ "$(SUDO_USER=root FAKE_ID_USER=bob privacy_user)" = "bob" ]
}

@test "render_firefox_policies is JSON that locks default_address_only" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  load_client_libs
  run bash -c 'python3 -c "import json,sys; d=json.load(sys.stdin); p=d[\"policies\"][\"Preferences\"][\"media.peerconnection.ice.default_address_only\"]; assert p[\"Value\"] is True and p[\"Status\"] == \"locked\", p"' <<<"$(render_firefox_policies)"
  [ "${status}" -eq 0 ]
}

@test "privacy_status is off by default, hardened when every value matches, partial otherwise" {
  load_client_libs
  write_privacy_config
  [ "$(privacy_status)" = "off" ]
  fake_hardened
  [ "$(FAKE_UID=0 privacy_status)" = "hardened" ]
  cp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
  [ "$(FAKE_UID=0 FAKE_COMPUTER_NAME="Test User's MacBook Pro" privacy_status)" = "partial" ]
  # Safari is not part of the summary (its settings may be unreadable).
  [ "$(FAKE_UID=0 FAKE_SAFARI=1 privacy_status)" = "hardened" ]
  [ "$(FAKE_UID=0 FAKE_LOCATION=1 FAKE_TZ_AUTO=1 FAKE_TIMEZONE=Asia/Almaty FAKE_APPLE_LOCALE=ru_KZ \
    FAKE_APPLE_LANGUAGES=ru-KZ FAKE_WEBRTC='' FAKE_LOOKUP='' FAKE_COMPUTER_NAME=x FAKE_HOST_NAME='' \
    FAKE_LOCAL_HOST_NAME=x privacy_status)" = "off" ]
}

# ---------------------------------------------------------------- oneexit harden

@test "harden --dry-run prints every defaults, systemsetup, scutil and launchctl command" {
  FAKE_APPLE_LOCALE=ru_KZ FAKE_APPLE_LANGUAGES="ru-KZ;en-US" \
    run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Berlin --region DE --dry-run
  [ "${status}" -eq 0 ]
  for line in \
    "defaults write /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd LocationServicesEnabled -int 0" \
    "launchctl kickstart -k system/com.apple.locationd" \
    "defaults write /Library/Preferences/com.apple.timezone.auto Active -bool false" \
    "systemsetup -settimezone Europe/Berlin" \
    "sudo -u tester -H defaults write -g AppleLocale -string ru_DE" \
    "sudo -u tester -H defaults write -g AppleLanguages -array ru en" \
    "scutil --set ComputerName Mac" \
    "scutil --set HostName Mac" \
    "scutil --set LocalHostName Mac" \
    "defaults write /Library/Preferences/com.google.Chrome WebRtcIPHandlingPolicy -string disable_non_proxied_udp" \
    "defaults write /Library/Preferences/com.brave.Browser WebRtcIPHandlingPolicy -string disable_non_proxied_udp" \
    "defaults write /Library/Preferences/com.microsoft.Edge WebRtcIPHandlingPolicy -string disable_non_proxied_udp" \
    "defaults write /Library/Preferences/org.chromium.Chromium WebRtcIPHandlingPolicy -string disable_non_proxied_udp" \
    "sudo -u tester -H defaults write com.apple.lookup.shared LookupSuggestionsDisabled -bool true" \
    "sudo -u tester -H defaults write com.apple.Safari UniversalSearchEnabled -bool false"; do
    printf '%s\n' "${output}" | grep -qxF "[dry-run] ${line}" || {
      echo "missing: ${line}"
      return 1
    }
  done
  [ ! -e "${ONEEXIT_PRIVACY_STATE}" ]
}

@test "harden --dry-run prints the state file with the current values" {
  FAKE_UID=0 FAKE_LOCATION=1 FAKE_TZ_AUTO=1 FAKE_APPLE_LOCALE=ru_KZ FAKE_APPLE_LANGUAGES="ru-KZ;en-US" \
    FAKE_WEBRTC=default FAKE_LOOKUP=0 \
    run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Berlin --region DE --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] write ${ONEEXIT_PRIVACY_STATE} (mode 0600):"* ]]
  state="$(dry_run_block "${output}" "${ONEEXIT_PRIVACY_STATE}")"
  for line in USER=tester LOCATION_SERVICES=1 TZ_AUTO=1 TIMEZONE=Asia/Almaty APPLE_LOCALE=ru_KZ \
    "APPLE_LANGUAGES=ru-KZ;en-US" "COMPUTER_NAME=Test User's MacBook Pro" HOST_NAME= \
    LOCAL_HOST_NAME=Testers-MacBook-Pro CHROME_WEBRTC_com.google.Chrome=present:default \
    CHROME_WEBRTC_org.chromium.Chromium=present:default FIREFOX_POLICY_CREATED=no \
    LOOKUP_SUGGESTIONS=0 SAFARI_UNIVERSAL_SEARCH=; do
    printf '%s\n' "${state}" | grep -qxF "${line}" || {
      echo "missing in state: ${line}"
      return 1
    }
  done
}

@test "harden leaves AppleLanguages alone when no entry names another region" {
  FAKE_APPLE_LOCALE=de_AT FAKE_APPLE_LANGUAGES="de-DE;en" \
    run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Berlin --region DE --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"defaults write -g AppleLocale -string de_DE"* ]]
  [[ "${output}" != *"AppleLanguages -array"* ]]
  [[ "${output}" == *"AppleLanguages (de-DE;en) name no other region"* ]]
}

@test "a second harden keeps the state file from the first one" {
  cp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
  run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Berlin --region DE --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"keeping ${ONEEXIT_PRIVACY_STATE}"* ]]
  [[ "${output}" != *"write ${ONEEXIT_PRIVACY_STATE}"* ]]
  cmp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
}

@test "harden takes TIMEZONE/REGION from the config, or stops with a hint" {
  run "${CLIENT_DIR}/oneexit" harden --dry-run
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"no time zone: pass --timezone"* ]]
  run "${CLIENT_DIR}/oneexit" harden --timezone Mars/Olympus --dry-run
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"unknown time zone: Mars/Olympus"* ]]
  run "${CLIENT_DIR}/oneexit" harden --timezone UTC --dry-run
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"no region known for UTC"* ]]
  run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Berlin --region DEU --dry-run
  [ "${status}" -eq 2 ]
  write_privacy_config Europe/Amsterdam NL
  run "${CLIENT_DIR}/oneexit" harden --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] systemsetup -settimezone Europe/Amsterdam"* ]]
  [[ "${output}" == *"AppleLocale -string en_NL"* ]]
}

@test "harden --timezone derives the region and stores both in the config" {
  write_privacy_config Europe/Berlin DE
  run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Amsterdam --dry-run
  [ "${status}" -eq 0 ]
  cfg="$(dry_run_block "${output}" "${ONEEXIT_CONFIG}")"
  [[ "${cfg}" == *"VPS_IP=203.0.113.5"* ]]
  [ "$(printf '%s\n' "${cfg}" | grep -c '^TIMEZONE=')" -eq 1 ]
  [[ "${cfg}" == *"TIMEZONE=Europe/Amsterdam"* ]]
  [[ "${cfg}" == *"REGION=NL"* ]]
  run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Amsterdam --region nl --dry-run
  [[ "${output}" == *"AppleLocale -string en_NL"* ]]
}

@test "harden writes the Firefox policy only if Firefox is installed and has none" {
  run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Berlin --dry-run
  [[ "${output}" == *"Firefox is not installed"* ]]
  [[ "${output}" != *"policies.json"* ]]
  mkdir -p "${ONEEXIT_APPLICATIONS_DIR}/Firefox.app/Contents/Resources"
  policy="${ONEEXIT_APPLICATIONS_DIR}/Firefox.app/Contents/Resources/distribution/policies.json"
  run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Berlin --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] write ${policy} (mode 0644):"* ]]
  [[ "${output}" == *'"media.peerconnection.ice.default_address_only": {'* ]]
  [ "$(dry_run_block "${output}" "${ONEEXIT_PRIVACY_STATE}" | grep '^FIREFOX')" = "FIREFOX_POLICY_CREATED=yes" ]
  mkdir -p "$(dirname "${policy}")"
  echo '{"policies": {}}' >"${policy}"
  run "${CLIENT_DIR}/oneexit" harden --timezone Europe/Berlin --dry-run
  [[ "${output}" == *"${policy} exists; not changing it"* ]]
  [[ "${output}" != *"write ${policy}"* ]]
  [ "$(dry_run_block "${output}" "${ONEEXIT_PRIVACY_STATE}" | grep '^FIREFOX')" = "FIREFOX_POLICY_CREATED=no" ]
}

@test "harden then unharden as (pretend) root against the stubs: state written once, then removed" {
  # Guard: every tool that changes settings must resolve to a stub.
  run bash -c '. "$1/lib/common.sh"; for t in defaults scutil systemsetup launchctl id; do command -v "$t"; done' _ "${CLIENT_DIR}"
  for tool in defaults scutil systemsetup launchctl id; do
    printf '%s\n' "${output}" | grep -qxF "${FIXTURES}/bin/${tool}" || skip "${tool} does not resolve to the stub"
  done
  write_privacy_config
  mkdir -p "${ONEEXIT_APPLICATIONS_DIR}/Firefox.app/Contents/Resources"
  policy="${ONEEXIT_APPLICATIONS_DIR}/Firefox.app/Contents/Resources/distribution/policies.json"
  FAKE_UID=0 FAKE_LOCATION=1 run "${CLIENT_DIR}/oneexit" harden
  [ "${status}" -eq 0 ]
  [ -f "${ONEEXIT_PRIVACY_STATE}" ]
  grep -qxF "LOCATION_SERVICES=1" "${ONEEXIT_PRIVACY_STATE}"
  grep -qxF "FIREFOX_POLICY_CREATED=yes" "${ONEEXIT_PRIVACY_STATE}"
  grep -q default_address_only "${policy}"
  cp "${ONEEXIT_PRIVACY_STATE}" "${BATS_TEST_TMPDIR}/first-state"
  FAKE_UID=0 FAKE_LOCATION=0 FAKE_COMPUTER_NAME=Mac run "${CLIENT_DIR}/oneexit" harden
  [ "${status}" -eq 0 ]
  cmp "${BATS_TEST_TMPDIR}/first-state" "${ONEEXIT_PRIVACY_STATE}"
  FAKE_UID=0 run "${CLIENT_DIR}/oneexit" unharden
  [ "${status}" -eq 0 ]
  [ ! -e "${ONEEXIT_PRIVACY_STATE}" ]
  [ ! -e "${policy}" ]
}

@test "harden and unharden have --help without root and reject unknown options" {
  run "${CLIENT_DIR}/oneexit" harden --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--timezone TZ"* ]]
  run "${CLIENT_DIR}/oneexit" unharden --help
  [ "${status}" -eq 0 ]
  run "${CLIENT_DIR}/oneexit" harden --bogus
  [ "${status}" -eq 2 ]
}

# ---------------------------------------------------------------- oneexit unharden

@test "unharden --dry-run restores exactly the recorded values" {
  cp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
  run "${CLIENT_DIR}/oneexit" unharden --dry-run
  [ "${status}" -eq 0 ]
  for line in \
    "defaults write /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd LocationServicesEnabled -int 1" \
    "launchctl kickstart -k system/com.apple.locationd" \
    "defaults delete /Library/Preferences/com.apple.timezone.auto Active" \
    "systemsetup -settimezone Asia/Almaty" \
    "sudo -u tester -H defaults write -g AppleLocale -string ru_KZ" \
    "sudo -u tester -H defaults write -g AppleLanguages -array ru-KZ en-US" \
    "scutil --set ComputerName 'Test User'\\''s MacBook Pro'" \
    "scutil --set HostName ''" \
    "scutil --set LocalHostName Testers-MacBook-Pro" \
    "sudo -u tester -H defaults write com.apple.lookup.shared LookupSuggestionsDisabled -bool false" \
    "sudo -u tester -H defaults delete com.apple.Safari UniversalSearchEnabled" \
    "rm -f ${ONEEXIT_APPLICATIONS_DIR}/Firefox.app/Contents/Resources/distribution/policies.json" \
    "rm -f ${ONEEXIT_PRIVACY_STATE}"; do
    printf '%s\n' "${output}" | grep -qxF "[dry-run] ${line}" || {
      echo "missing: ${line}"
      return 1
    }
  done
  [ -e "${ONEEXIT_PRIVACY_STATE}" ]
}

@test "unharden removes a Chrome-family key only if it was absent before" {
  cp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
  run "${CLIENT_DIR}/oneexit" unharden --dry-run
  [ "${status}" -eq 0 ]
  printf '%s\n' "${output}" | grep -qxF "[dry-run] defaults delete /Library/Preferences/com.google.Chrome WebRtcIPHandlingPolicy"
  printf '%s\n' "${output}" | grep -qxF "[dry-run] defaults delete /Library/Preferences/org.chromium.Chromium WebRtcIPHandlingPolicy"
  printf '%s\n' "${output}" | grep -qxF "[dry-run] defaults write /Library/Preferences/com.brave.Browser WebRtcIPHandlingPolicy -string default_public_interface_only"
  [[ "${output}" != *"delete /Library/Preferences/com.brave.Browser"* ]]
  [[ "${output}" != *"/Library/Preferences/com.microsoft.Edge"* ]]
}

@test "unharden without a state file has nothing to restore" {
  run "${CLIENT_DIR}/oneexit" unharden --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"nothing to restore"* ]]
  [[ "${output}" != *"[dry-run] "* ]]
}

# ---------------------------------------------------------------- status and doctor

@test "oneexit status shows the privacy line" {
  write_privacy_config
  run "${CLIENT_DIR}/oneexit" status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"privacy:      off"* ]]
  fake_hardened
  cp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
  FAKE_UID=0 run "${CLIENT_DIR}/oneexit" status
  [[ "${output}" == *"privacy:      hardened"* ]]
  FAKE_UID=0 FAKE_TIMEZONE=Asia/Almaty run "${CLIENT_DIR}/oneexit" status
  [[ "${output}" == *"privacy:      partial"* ]]
}

@test "oneexit doctor lists each privacy setting; mismatches fail only after harden" {
  write_privacy_config
  run "${CLIENT_DIR}/oneexit" doctor
  [[ "${output}" == *"Privacy"* ]]
  [[ "${output}" == *"not hardened (sudo oneexit harden)"* ]]
  printf '%s\n' "${output}" | grep -q '^  \.\.    computer name    Test User.s MacBook Pro (harden sets: Mac)$'
  printf '%s\n' "${output}" | grep -q '^  \.\.    location         unknown (needs sudo)$'
  [[ "${output}" != *"FAIL  computer name"* ]]
  cp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
  FAKE_UID=0 FAKE_LOCATION=1 run "${CLIENT_DIR}/oneexit" doctor
  printf '%s\n' "${output}" | grep -q '^  FAIL  computer name    Test User.s MacBook Pro (expected Mac)$'
  printf '%s\n' "${output}" | grep -q '^  FAIL  location         on (1) (expected off (0))$'
  printf '%s\n' "${output}" | grep -q '^  FAIL  time zone        Asia/Almaty (expected Europe/Berlin)$'
}

# ---------------------------------------------------------------- setup and uninstall

@test "setup.sh --dry-run takes the time zone from the peer comment and hardens" {
  FAKE_DISK=external run "${CLIENT_DIR}/setup.sh" --config "${FIXTURES}/peer-tz.conf" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"time zone Europe/Amsterdam (from the server"* ]]
  cfg="$(dry_run_block "${output}" "${ONEEXIT_CONFIG}")"
  [[ "${cfg}" == *"TIMEZONE=Europe/Amsterdam"* ]]
  [[ "${cfg}" == *"REGION=NL"* ]]
  [[ "${output}" == *"[dry-run] systemsetup -settimezone Europe/Amsterdam"* ]]
  [[ "${output}" == *"[dry-run] scutil --set ComputerName Mac"* ]]
  [[ "${output}" == *"[dry-run] write ${ONEEXIT_PRIVACY_STATE} (mode 0600):"* ]]
  [[ "${output}" == *"lib/privacy.sh ${ONEEXIT_LIBEXEC}/lib/privacy.sh"* ]]
}

@test "setup.sh defaults to Europe/Berlin and DE; --timezone/--region override; bad values are usage errors" {
  FAKE_DISK=external run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --dry-run
  [ "${status}" -eq 0 ]
  cfg="$(dry_run_block "${output}" "${ONEEXIT_CONFIG}")"
  [[ "${cfg}" == *"TIMEZONE=Europe/Berlin"* ]]
  [[ "${cfg}" == *"REGION=DE"* ]]
  FAKE_DISK=external run "${CLIENT_DIR}/setup.sh" --config "${FIXTURES}/peer-tz.conf" \
    --timezone Asia/Almaty --region kz --dry-run
  [ "${status}" -eq 0 ]
  cfg="$(dry_run_block "${output}" "${ONEEXIT_CONFIG}")"
  [[ "${cfg}" == *"TIMEZONE=Asia/Almaty"* ]]
  [[ "${cfg}" == *"REGION=KZ"* ]]
  run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --timezone Mars/Olympus --dry-run
  [ "${status}" -eq 2 ]
  run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --region Germany --dry-run
  [ "${status}" -eq 2 ]
}

@test "setup.sh --no-harden stores TIMEZONE/REGION but changes no privacy setting" {
  FAKE_DISK=external run "${CLIENT_DIR}/setup.sh" --config "${FIXTURES}/peer-tz.conf" --no-harden --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Skipping the privacy hardening (--no-harden)"* ]]
  [[ "$(dry_run_block "${output}" "${ONEEXIT_CONFIG}")" == *"TIMEZONE=Europe/Amsterdam"* ]]
  [[ "${output}" != *"systemsetup"* ]]
  [[ "${output}" != *"scutil"* ]]
  [[ "${output}" != *"privacy-state"* ]]
}

@test "setup.sh re-run keeps the privacy state of the first harden" {
  cp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
  FAKE_DISK=external run "${CLIENT_DIR}/setup.sh" --config "${PEER_CONF}" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"keeping ${ONEEXIT_PRIVACY_STATE}"* ]]
  [[ "${output}" != *"write ${ONEEXIT_PRIVACY_STATE}"* ]]
}

@test "uninstall.sh --dry-run restores the privacy settings first, if harden ran" {
  run "${CLIENT_DIR}/uninstall.sh" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Restoring the settings changed by oneexit harden"* ]]
  cp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
  run "${CLIENT_DIR}/uninstall.sh" --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"[dry-run] systemsetup -settimezone Asia/Almaty"* ]]
  [[ "${output}" == *"[dry-run] scutil --set LocalHostName Testers-MacBook-Pro"* ]]
  [[ "${output}" == *"[dry-run] rm -f ${ONEEXIT_PRIVACY_STATE}"* ]]
  restore_line="$(printf '%s\n' "${output}" | grep -n 'systemsetup -settimezone' | cut -d: -f1)"
  bootout_line="$(printf '%s\n' "${output}" | grep -n 'launchctl bootout' | head -n 1 | cut -d: -f1)"
  [ "${restore_line}" -lt "${bootout_line}" ]
}

@test "uninstall.sh --keep-privacy leaves the settings and prints the old values" {
  cp "${FIXTURES}/privacy-state" "${ONEEXIT_PRIVACY_STATE}"
  run "${CLIENT_DIR}/uninstall.sh" --keep-privacy --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Keeping the privacy settings (--keep-privacy)"* ]]
  [[ "${output}" == *"TIMEZONE=Asia/Almaty"* ]]
  [[ "${output}" != *"systemsetup -settimezone"* ]]
  [[ "${output}" != *"scutil --set"* ]]
}

# ---------------------------------------------------------------- leak test 9-12

@test "leak-test 9-12 PASS on a hardened Mac" {
  write_privacy_config
  fake_hardened
  FAKE_UID=0 run "${REPO_ROOT}/scripts/leak-test.sh"
  printf '%s\n' "${output}" | grep -q '^PASS  timezone   time zone Europe/Berlin, automatic time zone off$'
  printf '%s\n' "${output}" | grep -q '^PASS  location   Location Services are off$'
  printf '%s\n' "${output}" | grep -q '^PASS  names      .*do not contain tester or Test User$'
  printf '%s\n' "${output}" | grep -q '^PASS  region     AppleLocale ru_DE names DE$'
}

@test "leak-test 9-12 FAIL on the values they guard against" {
  write_privacy_config
  fake_hardened
  FAKE_UID=0 FAKE_TIMEZONE=Asia/Almaty FAKE_LOCATION=1 FAKE_COMPUTER_NAME="Test User's MacBook Pro" \
    FAKE_APPLE_LOCALE=ru_KZ run "${REPO_ROOT}/scripts/leak-test.sh"
  [ "${status}" -eq 1 ]
  printf '%s\n' "${output}" | grep -q '^FAIL  timezone   system time zone is Asia/Almaty, not Europe/Berlin'
  printf '%s\n' "${output}" | grep -q '^FAIL  location   Location Services are on'
  printf '%s\n' "${output}" | grep -q '^FAIL  names      ComputerName "Test User.s MacBook Pro" contains "Test User"'
  printf '%s\n' "${output}" | grep -q '^FAIL  region     AppleLocale ru_KZ names KZ, not DE$'
  FAKE_UID=0 FAKE_TZ_AUTO=1 FAKE_LOCATION='' FAKE_LOCAL_HOST_NAME=testers-mac run "${REPO_ROOT}/scripts/leak-test.sh"
  printf '%s\n' "${output}" | grep -q '^FAIL  timezone   .*automatic time zone is on'
  printf '%s\n' "${output}" | grep -q '^FAIL  location   Location Services preference is missing'
  printf '%s\n' "${output}" | grep -q '^FAIL  names      LocalHostName "testers-mac" contains "tester"'
}

@test "leak-test 9-12 SKIP without root or without TIMEZONE/REGION" {
  write_test_config
  fake_hardened
  run "${REPO_ROOT}/scripts/leak-test.sh"
  printf '%s\n' "${output}" | grep -q '^SKIP  timezone   no TIMEZONE in '
  printf '%s\n' "${output}" | grep -q '^SKIP  location   needs root'
  printf '%s\n' "${output}" | grep -q '^PASS  names '
  printf '%s\n' "${output}" | grep -q '^SKIP  region     no REGION in '
  write_privacy_config
  run "${REPO_ROOT}/scripts/leak-test.sh"
  printf '%s\n' "${output}" | grep -q '^SKIP  timezone   needs root'
  printf '%s\n' "${output}" | grep -q '^PASS  region '
}

@test "leak-test exit code: 0 when all 12 checks pass, 1 for a single privacy FAIL" {
  write_privacy_config
  fake_hardened
  export FAKE_UID=0 FAKE_PFCTL=hook FAKE_WHOAMI=203.0.113.5 ONEEXIT_WG_RUN_DIR="${FIXTURES}/wireguard"
  run "${REPO_ROOT}/scripts/leak-test.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"0 FAIL(s)"* ]]
  FAKE_LOCATION=1 run "${REPO_ROOT}/scripts/leak-test.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"1 FAIL(s)"* ]]
}

@test "leak-test --json includes checks 9-12" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  write_privacy_config
  fake_hardened
  FAKE_UID=0 FAKE_LOCATION=1 run bash -c '"$1" --json 2>/dev/null | python3 -c "import json,sys; d={c[\"check\"]: c[\"status\"] for c in json.load(sys.stdin)}; print(d[\"timezone\"], d[\"location\"], d[\"names\"], d[\"region\"], len(d))"' _ "${REPO_ROOT}/scripts/leak-test.sh"
  [ "${status}" -eq 0 ]
  [ "${output}" = "PASS FAIL PASS PASS 12" ]
}
