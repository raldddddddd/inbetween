#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
configuration=${CONFIGURATION:-release}
app_dir=${APP_PATH:-"$project_root/.build/apps/$configuration/Inbetween.app"}
info_plist="$app_dir/Contents/Info.plist"
executable="$app_dir/Contents/MacOS/Inbetween"
expected_identifier="com.inbetween.app"

if [[ ! -d "$app_dir" ]]; then
  print -u2 -- "App bundle not found: $app_dir"
  exit 66
fi

if [[ ! -f "$info_plist" || ! -x "$executable" ]]; then
  print -u2 -- "App bundle is missing its Info.plist or executable."
  exit 65
fi

plutil -lint "$info_plist" >/dev/null
identifier=$(plutil -extract CFBundleIdentifier raw "$info_plist")
short_version=$(plutil -extract CFBundleShortVersionString raw "$info_plist")
build_version=$(plutil -extract CFBundleVersion raw "$info_plist")
menu_bar_only=$(plutil -extract LSUIElement raw "$info_plist")

if [[ "$identifier" != "$expected_identifier" ]]; then
  print -u2 -- "Unexpected bundle identifier: $identifier"
  exit 65
fi

if [[ -z "$short_version" || -z "$build_version" || "$menu_bar_only" != "true" ]]; then
  print -u2 -- "Release metadata is incomplete or LSUIElement is not enabled."
  exit 65
fi

codesign --verify --deep --strict --verbose=2 "$app_dir"
signature_details=$(codesign -d --verbose=2 "$app_dir" 2>&1)
if [[ "$signature_details" != *"Identifier=$expected_identifier"* ]]; then
  print -u2 -- "Code signature does not match the expected bundle identifier."
  exit 65
fi
signature_entitlements=$(codesign -d --entitlements - "$app_dir" 2>/dev/null)
if [[ "$signature_entitlements" != *"com.apple.security.automation.apple-events"* ]]; then
  print -u2 -- "Code signature is missing the Apple Events automation entitlement."
  exit 65
fi

print -r -- "Verified Inbetween $short_version ($build_version): $app_dir"
