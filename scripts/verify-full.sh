#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
cd "$project_root"

print -r -- "== Fast verification =="
"$project_root/scripts/verify-fast.sh"

print -r -- "== Debug bundle =="
CONFIGURATION=debug "$project_root/scripts/build-app.sh"

print -r -- "== Release bundle =="
CONFIGURATION=release "$project_root/scripts/build-app.sh"

print -r -- "== Release bundle metadata, signature, entitlements, and LSUIElement =="
CONFIGURATION=release "$project_root/scripts/verify-release.sh"

print -r -- "== Isolated clean-install bundle =="
APP_PATH="$project_root/.build/apps/release/Inbetween.app" "$project_root/scripts/test-clean-install.sh"

print -r -- "FULL VERIFICATION PASSED"
