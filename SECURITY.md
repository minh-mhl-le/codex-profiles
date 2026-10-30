# Security policy

Codex Profiles handles authentication material, so credential safety takes priority over convenient debugging.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/minh-mhl-le/codex-profiles/security/advisories/new) for issues involving credentials, Keychain access, account identity, auth-file replacement, privilege boundaries, or rollback behavior.

Do not open a public issue containing:

- `auth.json` or any portion of it;
- access, refresh, or identity tokens;
- cookies or browser session data;
- Keychain contents;
- account IDs; or
- raw logs or screenshots that may contain those values.

Include only the minimum sanitized reproduction details: Codex Profiles version, Codex version, macOS version, expected behavior, observed behavior, and whether the issue reproduces with a newly added account.

## Supported versions

Security fixes are made against the latest published source release. v0.1.x is experimental and may require updates when Codex internals change.

## Design boundaries

- Inactive credentials are stored in macOS Keychain with device-local accessibility.
- The live Codex auth file is written with owner-only permissions.
- Account switches are blocked while Codex reports active work.
- A failed switch restores the previous live auth when possible.
- There is no telemetry or background account polling.
- Credential handoff to local RATH workers is disabled by default. Consent and
  the explicit profile allowlist are stored in the app's Keychain item; ordinary
  user defaults do not enable the helper. Policy queries are scoped to one
  default keychain so search-list items cannot shadow consent. An upgrade requires fresh opt-in.
  It requires the user's Settings opt-in and explicit selection of every allowed profile.
  The helper accepts one explicit profile and job ID, verifies refreshed account
  identity, and releases credentials only on a captured stdout pipe.
- Handoff verification uses the existing isolated app-server flow: credentials
  briefly reside in a 0600 file inside a random 0700 temporary `CODEX_HOME`, which
  is removed when the request finishes. Rotated credentials return to Keychain.
- The receiving RATH process must keep payloads out of logs, diagnostics and
  persistent state. A job ID scopes delivery; it does not revoke bearer tokens.

This project is independent of and unaffiliated with OpenAI.
