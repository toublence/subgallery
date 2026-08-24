#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_PATH="${APP_PATH:-/tmp/SubGalleryStoreShotDerived/Build/Products/Release-iphonesimulator/SubGallery.app}"
BUNDLE_ID="com.namslab.subgallery"
CAPTURE_DELAY="${CAPTURE_DELAY:-3}"
IPHONE_ID="CDED8252-6713-4764-91A5-C4C1B7980292"
IPAD_ID="FF645163-1A38-472E-8A31-6E155192DF66"
if [[ -n "${STORE_SCREENS:-}" ]]; then
  SCREENS=(${=STORE_SCREENS})
else
  SCREENS=(library camera retention albums search batch security)
fi
LOCALES=("$@")

if (( ${#LOCALES[@]} == 0 )); then
  LOCALES=(en-US de-DE es-ES ar-SA ja-JP zh-Hans zh-Hant fr-FR)
fi

locale_values() {
  case "$1" in
    en-US) echo "en|en|en_US" ;;
    de-DE) echo "de|de|de_DE" ;;
    es-ES) echo "es|es|es_ES" ;;
    ar-SA) echo "ar|ar|ar_SA" ;;
    ja-JP) echo "ja|ja|ja_JP" ;;
    zh-Hans) echo "zh-Hans|zh-Hans|zh_CN" ;;
    zh-Hant) echo "zh-Hant|zh-Hant|zh_TW" ;;
    fr-FR) echo "fr|fr|fr_FR" ;;
    *) echo "Unknown locale: $1" >&2; return 1 ;;
  esac
}

boot_in_locale() {
  local udid="$1" apple_language="$2" apple_locale="$3"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl spawn "$udid" defaults write NSGlobalDomain AppleLanguages -array "$apple_language"
  xcrun simctl spawn "$udid" defaults write NSGlobalDomain AppleLocale "$apple_locale"
  xcrun simctl shutdown "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null
  xcrun simctl install "$udid" "$APP_PATH"
}

capture_device() {
  local locale="$1" device="$2" udid="$3" app_language="$4" apple_language="$5" apple_locale="$6"
  local destination="$ROOT/store-assets/source/$locale/$device"
  mkdir -p "$destination"
  for screen in $SCREENS; do
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    local launched=false
    for attempt in 1 2 3; do
      if xcrun simctl launch "$udid" "$BUNDLE_ID" \
        -store-screenshot -store-screen "$screen" \
        -app.language "$app_language" \
        -AppleLanguages "($apple_language)" \
        -AppleLocale "$apple_locale" >/dev/null 2>&1; then
        launched=true
        break
      fi
      sleep 5
      xcrun simctl boot "$udid" >/dev/null 2>&1 || true
      xcrun simctl bootstatus "$udid" -b >/dev/null
      xcrun simctl install "$udid" "$APP_PATH"
    done
    if [[ "$launched" != true ]]; then
      echo "Unable to launch $locale/$device/$screen after three attempts" >&2
      return 1
    fi
    sleep "$CAPTURE_DELAY"
    xcrun simctl io "$udid" screenshot "$destination/$screen.png" >/dev/null
  done
}

for locale in $LOCALES; do
  IFS='|' read -r app_language apple_language apple_locale <<< "$(locale_values "$locale")"
  echo "Capturing $locale"
  boot_in_locale "$IPHONE_ID" "$apple_language" "$apple_locale" &
  iphone_boot_pid=$!
  boot_in_locale "$IPAD_ID" "$apple_language" "$apple_locale" &
  ipad_boot_pid=$!
  wait "$iphone_boot_pid"
  wait "$ipad_boot_pid"
  capture_device "$locale" iphone "$IPHONE_ID" "$app_language" "$apple_language" "$apple_locale" &
  iphone_capture_pid=$!
  capture_device "$locale" ipad "$IPAD_ID" "$app_language" "$apple_language" "$apple_locale" &
  ipad_capture_pid=$!
  wait "$iphone_capture_pid"
  wait "$ipad_capture_pid"
done

echo "Localized source capture complete"
