#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
derived_data="$project_root/store-assets/DerivedData"
release_app="$project_root/store-assets/build/SubGallery.app"
raw_root="$project_root/store-assets/raw"
build_log="$project_root/store-assets/build-release-screenshots.log"
bundle_id="com.namslab.subgallery"

locales=(ko-KR en-US de-DE es-ES ar-SA ja-JP zh-Hans zh-Hant fr-FR)
routes=(library workflows receipt-report document-pdf qr-builder travel-map album-automation)

language_for_locale() {
  case "$1" in
    ko-KR) echo ko ;;
    en-US) echo en ;;
    de-DE) echo de ;;
    es-ES) echo es ;;
    ar-SA) echo ar ;;
    ja-JP) echo ja ;;
    zh-Hans) echo zh-Hans ;;
    zh-Hant) echo zh-Hant ;;
    fr-FR) echo fr ;;
  esac
}

apple_locale_for_locale() {
  case "$1" in
    ko-KR) echo ko_KR ;;
    en-US) echo en_US ;;
    de-DE) echo de_DE ;;
    es-ES) echo es_ES ;;
    ar-SA) echo ar_SA ;;
    ja-JP) echo ja_JP ;;
    zh-Hans) echo zh_CN ;;
    zh-Hant) echo zh_TW ;;
    fr-FR) echo fr_FR ;;
  esac
}

device_id_named() {
  xcrun simctl list devices available | awk -v wanted="$1" '
    index($0, "    " wanted " (") == 1 {
      if (match($0, /\([0-9A-F-]+\)/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  '
}

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "Building Release screenshot binary"
  xcodebuild \
    -project "$project_root/SubGallery.xcodeproj" \
    -scheme SubGallery \
    -configuration Release \
    -sdk iphonesimulator \
    -derivedDataPath "$derived_data" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) STORE_SCREENSHOTS' \
    CODE_SIGNING_ALLOWED=NO \
    build >"$build_log" 2>&1

  built_app="$derived_data/Build/Products/Release-iphonesimulator/SubGallery.app"
  if [[ ! -d "$built_app" ]]; then
    echo "Release app not found: $built_app" >&2
    exit 1
  fi
  mkdir -p "${release_app:h}"
  ditto "$built_app" "$release_app"
fi

app_path="$release_app"
if [[ ! -d "$app_path" ]]; then
  echo "Preserved Release app not found: $app_path" >&2
  exit 1
fi

iphone_udid="$(device_id_named 'iPhone 17 Pro Max')"
ipad_udid="$(device_id_named 'StoreShot iPad 13')"
if [[ -z "$iphone_udid" || -z "$ipad_udid" ]]; then
  echo "Required simulators are unavailable" >&2
  exit 1
fi

if [[ "${RESUME:-0}" != "1" ]]; then
  find "$raw_root" -type f -name '*.png' -delete
fi

capture_device() {
  local family="$1"
  local udid="$2"

  if [[ "${RESUME:-0}" == "1" ]]; then
    local existing_count="$(find "$raw_root" -path "*/$family/*.png" -type f | wc -l | tr -d ' ')"
    if [[ "$existing_count" == "63" ]]; then
      echo "kept all $family captures"
      return
    fi
  fi

  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  sleep 2
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" override \
    --time 9:41 \
    --batteryState charged \
    --batteryLevel 100 \
    --wifiBars 3 \
    --cellularBars 4 >/dev/null 2>&1 || true
  for locale in "${locales[@]}"; do
    local language="$(language_for_locale "$locale")"
    local apple_locale="$(apple_locale_for_locale "$locale")"
    local destination="$raw_root/$locale/$family"
    mkdir -p "$destination"
    xcrun simctl uninstall "$udid" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl install "$udid" "$app_path"

    for route in "${routes[@]}"; do
      if [[ "${RESUME:-0}" == "1" && -s "$destination/$route.png" ]]; then
        echo "kept $locale/$family/$route"
        continue
      fi
      xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" \
        -store-screenshot \
        -store-screen "$route" \
        -app.language "$language" \
        -AppleLanguages "($language)" \
        -AppleLocale "$apple_locale" >/dev/null

      case "$route" in
        library|workflows) sleep 8 ;;
        receipt-report) sleep 15 ;;
        document-pdf) sleep 30 ;;
        travel-map) sleep 7 ;;
        *) sleep 3 ;;
      esac

      xcrun simctl io "$udid" screenshot --type=png "$destination/$route.png" >/dev/null
      echo "captured $locale/$family/$route"
    done
  done
}

capture_device iphone "$iphone_udid"
capture_device ipad "$ipad_udid"

echo "Captured 126 localized release screenshots"
