#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
source_app=${APP_PATH:-"$project_root/.build/apps/release/Inbetween.app"}

if [[ ! -d "$source_app" ]]; then
  print -u2 -- "Release app bundle not found: $source_app"
  print -u2 -- "Build one first with: CONFIGURATION=release ./scripts/build-app.sh"
  exit 66
fi

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/inbetween-clean-install.XXXXXX")
trap 'rm -rf "$staging_root"' EXIT
installed_app="$staging_root/Applications/Inbetween.app"

mkdir -p "$staging_root/Applications"
ditto "$source_app" "$installed_app"
APP_PATH="$installed_app" "$project_root/scripts/verify-release.sh"

print -r -- "Clean-install bundle check passed."
