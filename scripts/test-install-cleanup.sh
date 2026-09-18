#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}/.."
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-profiles-install-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/bin" "$TEST_ROOT/Applications"
cp "$ROOT_DIR/scripts/install-app.sh" "$TEST_ROOT/scripts/install-app.sh"

cat > "$TEST_ROOT/scripts/build-app.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h}/.."
mkdir -p "$ROOT_DIR/dist/Codex Profiles.app/Contents/MacOS"
touch "$ROOT_DIR/dist/Codex Profiles.app/Contents/MacOS/CodexProfiles"
chmod +x "$ROOT_DIR/dist/Codex Profiles.app/Contents/MacOS/CodexProfiles"
EOF
chmod +x "$TEST_ROOT/scripts/build-app.sh"

cat > "$TEST_ROOT/bin/osascript" <<'EOF'
#!/bin/zsh
exit 0
EOF
cat > "$TEST_ROOT/bin/open" <<'EOF'
#!/bin/zsh
exit 0
EOF
chmod +x "$TEST_ROOT/bin/osascript" "$TEST_ROOT/bin/open"

PATH="$TEST_ROOT/bin:$PATH" \
CODEX_PROFILES_TARGET_APP="$TEST_ROOT/Applications/Codex Profiles.app" \
zsh "$TEST_ROOT/scripts/install-app.sh"

test -x "$TEST_ROOT/Applications/Codex Profiles.app/Contents/MacOS/CodexProfiles"
test ! -e "$TEST_ROOT/dist/Codex Profiles.app"
echo "Installer cleanup test passed"
