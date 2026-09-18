# Contributing

Codex Profiles is intentionally small. Focused bug fixes, Codex compatibility updates, accessibility improvements, and concise documentation changes are welcome.

## Local development

Requirements are an Apple Silicon Mac, macOS 13 or newer, Xcode Command Line Tools, and the official Codex desktop app.

```sh
git clone https://github.com/minh-mhl-le/codex-profiles.git
cd codex-profiles
swift build
```

Logic tests use XCTest and require a full Xcode installation:

```sh
swift test
```

Build the app bundle with:

```sh
zsh scripts/build-app.sh
```

Exercise installer cleanup in an isolated temporary directory with:

```sh
zsh scripts/test-install-cleanup.sh
```

## Pull requests

- Keep changes scoped to one problem.
- Preserve the active-task check, identity verification, atomic auth replacement, and rollback path.
- Add or update tests for logic changes where practical.
- Verify a release build and the affected menu-bar flow.
- For installer changes, verify that a successful install leaves only the `/Applications` app bundle and removes the generated `dist/` bundle.
- For release changes, keep `AppMetadata.version`, `Resources/Info.plist`, and `CHANGELOG.md` in sync.
- Update user-facing documentation when behavior changes.
- Never commit credentials, profile metadata, personal screenshots, or unredacted logs.

For vulnerabilities involving auth or Keychain behavior, do not open a pull request or public issue first. Follow [SECURITY.md](SECURITY.md).
