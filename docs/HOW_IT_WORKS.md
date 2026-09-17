# How it works

Codex Profiles is a small companion around the authentication state used by the Codex desktop app. It does not patch Codex or maintain a separate workspace.

## Storage

| Data | Location | Purpose |
| --- | --- | --- |
| Active Codex credentials | `~/.codex/auth.json` | The one account Codex currently uses |
| Inactive saved credentials | macOS Keychain | Encrypted account cache managed by the OS |
| Profile names and account metadata | `~/Library/Application Support/Codex Profiles/` | Non-secret local profile list and active-profile marker |
| Projects, tasks, drafts, settings, and caches | Existing `~/.codex/` contents | Left in place across account switches |

The repository stores no credentials.

## Adding an account

Add account starts the official ChatGPT login request through Codex’s bundled `codex app-server`. The browser completes authentication. Codex Profiles then stores the returned auth data in Keychain without changing the currently active Codex account.

## Reading usage

Each saved account is checked in an isolated temporary `CODEX_HOME`. Codex Profiles asks `codex app-server` for account details and rate limits, updates the visible usage snapshot, then removes the temporary directory. It refreshes on panel open when enabled, or when the user presses Refresh. It does not poll in the background.

## Switching accounts

The switch is intentionally conservative:

1. Ask Codex whether any task is active. Unknown or active state blocks the switch.
2. Verify the target credential. If it expired, restart the normal browser sign-in flow and require the returned identity to match the saved profile.
3. Ask Codex to quit and verify that it exited.
4. Preserve the current live auth in Keychain.
5. Atomically replace `~/.codex/auth.json` with the selected credential.
6. Record the selected profile and reopen Codex if enabled.

If replacement or verification fails after Codex quits, the previous live auth is restored before Codex reopens.

## Compatibility boundary

The app currently discovers and calls the `codex app-server` executable bundled with the Codex desktop app. That is an internal integration boundary, not a stable public API. A future Codex release may require a compatibility update here even when the UI and stored profiles remain unchanged.

Codex Profiles v0.1.0 supports Apple Silicon and macOS 13 or newer.
