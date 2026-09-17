#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
SOURCE_APP="$ROOT_DIR/dist/Codex Profiles.app"
TARGET_APP="/Applications/Codex Profiles.app"

zsh "$ROOT_DIR/scripts/build-app.sh"

osascript -e 'tell application id "io.github.minh-mhl-le.CodexProfiles" to quit' >/dev/null 2>&1 || true
sleep 1
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
open "$TARGET_APP"

echo "Installed and opened $TARGET_APP"
