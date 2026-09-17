# Agent setup

This guide is for a local coding agent setting up Codex Profiles on a user’s Mac. The expected result is a locally built app installed at `/Applications/Codex Profiles.app`, launched and visible in the menu bar.

## Safety contract

The agent may inspect this repository and run its build/install scripts. It must not:

- read, print, copy, summarize, or directly edit `~/.codex/auth.json`;
- inspect tokens, cookies, Keychain values, or browser session data;
- automate browser authentication or type a Keychain password;
- delete saved profiles or change the active Codex account during setup; or
- bypass Gatekeeper, Keychain, or macOS security controls.

Browser sign-in and Keychain approval belong to the human user.

## 1. Verify prerequisites

Run only non-sensitive checks:

```sh
uname -m
sw_vers -productVersion
xcode-select -p
test -d "/Applications/Codex.app" -o -d "/Applications/ChatGPT.app"
```

Expected:

- `uname -m` returns `arm64`;
- macOS is version 13 or newer;
- Xcode Command Line Tools are installed; and
- the official Codex desktop app is installed.

If Command Line Tools are missing, ask the user to run `xcode-select --install` and finish Apple’s installer before continuing.

## 2. Clone or update

For a new installation:

```sh
git clone https://github.com/minh-mhl-le/codex-profiles.git
cd codex-profiles
```

For an existing clean checkout:

```sh
git pull --ff-only
```

Do not discard or overwrite local changes. If the checkout is dirty, stop and tell the user which files are modified.

## 3. Build, install, and launch

Read `scripts/build-app.sh` and `scripts/install-app.sh`, then run:

```sh
zsh scripts/install-app.sh
```

The installer builds a release executable, creates an ad-hoc signed app bundle, copies it to `/Applications`, and opens it. It does not read Codex credentials.

## 4. Verify the installation

Use non-sensitive checks:

```sh
test -x "/Applications/Codex Profiles.app/Contents/MacOS/CodexProfiles"
codesign --verify --deep --strict "/Applications/Codex Profiles.app"
pgrep -x CodexProfiles
```

Confirm that the Codex Profiles icon is visible in the menu bar. Do not open or inspect credential files while troubleshooting.

## 5. Hand control to the user

Tell the user to:

1. Click the Codex Profiles menu-bar icon.
2. Choose **Always Allow** if macOS asks for Keychain access.
3. Press **Add account** for each additional account.
4. Complete every browser sign-in themselves.
5. Finish any running Codex task before switching profiles.

Setup is complete when the panel opens, saved profiles appear, and usage can refresh. Authentication does not need to be exercised as part of the agent’s verification.

## Troubleshooting boundaries

It is safe to inspect build output, process state, code signatures, app logs that have been checked for credentials, and menu-bar visibility. It is not safe to dump environment variables, Keychain records, `auth.json`, or raw Codex logs into chat or an issue.

If the app no longer works after a Codex update, report the Codex version, Codex Profiles version, macOS version, and sanitized behavior—never credential contents.
