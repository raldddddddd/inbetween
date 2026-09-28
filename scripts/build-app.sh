#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
configuration=${CONFIGURATION:-debug}
app_dir="$project_root/.build/apps/$configuration/Inbetween.app"
contents_dir="$app_dir/Contents"
signing_identity=${CODE_SIGN_IDENTITY:--}
entitlements="$project_root/Support/Inbetween.entitlements"

case "$configuration" in
  debug|release) ;;
  *)
    print -u2 -- "Unsupported CONFIGURATION: $configuration (use debug or release)."
    exit 64
    ;;
esac

cd "$project_root"
swift build --configuration "$configuration" --product Inbetween
binary_dir=$(swift build --configuration "$configuration" --show-bin-path)

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_root/Support/Inbetween-Info.plist" "$contents_dir/Info.plist"
cp "$binary_dir/Inbetween" "$contents_dir/MacOS/Inbetween"
chmod 755 "$contents_dir/MacOS/Inbetween"

plutil -lint "$contents_dir/Info.plist" >/dev/null

if [[ "$signing_identity" == "-" ]]; then
  codesign --force --sign - --entitlements "$entitlements" --identifier com.inbetween.app "$app_dir"
else
  codesign --force --options runtime --timestamp --sign "$signing_identity" --entitlements "$entitlements" --identifier com.inbetween.app "$app_dir"
fi

codesign --verify --deep --strict --verbose=2 "$app_dir"

print -r -- "$app_dir"
