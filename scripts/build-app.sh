#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/Codex Profiles.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"
BUNDLE_IDENTIFIER="io.github.minh-mhl-le.CodexProfiles"

cd "$ROOT_DIR"

# Some Command Line Tools installations briefly ship a newer Swift compiler
# beside the previous macOS SDK. Build against the compatibility SDK when it
# is available; Xcode installations continue to use their selected SDK.
if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
  export SDKROOT="${CODEX_PROFILES_SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
elif [[ -n "${CODEX_PROFILES_SDKROOT:-}" ]]; then
  export SDKROOT="$CODEX_PROFILES_SDKROOT"
fi

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/CodexProfiles" "$MACOS_DIR/CodexProfiles"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"

chmod 755 "$MACOS_DIR/CodexProfiles"
codesign \
  --force \
  --deep \
  --sign - \
  --identifier "$BUNDLE_IDENTIFIER" \
  --requirements "=designated => identifier \"$BUNDLE_IDENTIFIER\"" \
  "$APP_DIR" >/dev/null
echo "Built $APP_DIR"
