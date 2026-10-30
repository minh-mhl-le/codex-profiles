# Local RATH handoff

This interface is disabled by default. In Settings, enable **Allow selected saved
profiles for RATH**, then individually select the accounts RATH may use. Consent
and the allowlist are stored in the app's Keychain item; mutable preference
defaults do not enable the helper. Keychain queries are scoped to the selected
default keychain so a matching item in another search-list keychain cannot
shadow the setting. Previously saved defaults are ignored, so users must enable
handoff again after upgrading this version. This authorizes trusted local
processes to receive those accounts' bearer credentials. The helper does not
authenticate an application identity: any same-user process can invoke it once
enabled. Disable the setting to stop future handoffs.

RATH invokes the built app's executable directly, without opening or switching
the desktop app. The exact argument shape is:

```text
CodexProfiles --rath-handoff pool --job <job UUID>
CodexProfiles --rath-handoff usage --profile <profile UUID> --job <job UUID>
CodexProfiles --rath-handoff auth --profile <profile UUID> --job <job UUID>
```

The caller must capture stdout as a pipe directly into its process memory. Do not
run the auth operation in a terminal pipeline, redirect it to a file, or print its
response. Stdout attached to a terminal or regular file is refused. There is no
listener, service, enable flag, or fallback to the live Codex login. Unknown/extra
arguments are rejected. `pool` refreshes only the selected pool and returns
`schemaVersion`, `jobId`, `profiles` (the safe usage objects below), and
`unavailableProfileIds` (selected UUIDs whose refresh failed). UUIDs outside the
pool are never listed. Pool work is capped at 32 selected profiles; response
output is capped at 1 MiB. Calls refresh profiles sequentially and may take up to
the existing app-server timeout per selected profile.

A successful call returns exactly one JSON line with `schemaVersion: 1`,
`profileId`, `jobId`, `observedAt` (Unix seconds), and `windows`. Each window
contains optional numeric `usedPercent`, `resetsAt` (Unix seconds), and
`windowDurationMinutes`. Responses preserve optional `ordinaryUsageAllowed`,
`rateLimitReachedType`, `spendControlReached`, and `individualLimit` gate fields.
`individualLimit` has optional decimal-string `limit`/`used` and numeric
`remainingPercent`/`resetsAt` values. Absent fields remain unknown; an account is
eligible only with `ordinaryUsageAllowed: true`. Auth is refused when this gate
is false, absent or conflicting. Spend-control and individual-limit fields are
diagnostics only and do not override that explicit gate. The parser accepts
known root and nested placements; deployed app-server versions may omit these
fields, in which case the account remains ineligible until capability is known.
An auth call adds `authPayloadBase64`, the base64 encoding
of the freshly verified auth record. Usage calls omit that field. Profile names,
emails, upstream account IDs, and upstream error text are never returned.

Each call checks the Settings allowlist before reading Keychain, refreshes the
account and usage through Codex's app-server, verifies the saved upstream account
ID (and email when saved), then stores any rotated credential back in Keychain.
Profiles without a saved account ID are refused; refresh them in the normal
Profiles UI first. Verification uses the existing app-server temporary-home
implementation, with a 0600 auth file inside a random 0700 directory, removed
after the call. Nothing changes the live Codex auth file or active profile.

Failure returns a nonzero exit status, empty stdout, and one sanitized stderr JSON
line with `schemaVersion` and a fixed `error` code: `invalid_request`,
`pipe_required`, `disabled`, `profile_not_allowed`, `identity_mismatch`, or
`unavailable`. Never log success stdout. A broken output pipe can interrupt the
single write; the caller must reject incomplete JSON and unsuccessful exits.

The job UUID binds the response to the requested worker job; these existing
bearer credentials are not intrinsically job-scoped and are not revoked when a
worker exits. The receiving process owns their lifetime. RATH's isolated worker
may create an owner-only, job-local auth file if its adapter requires one, must
exclude it from logs/checkpoints, and must remove it after the job.

No real profile, Keychain entry, auth file, or app-server is used by the handoff
tests. All service tests use fake stores, fake account clients and arbitrary
non-credential bytes. Building/testing this patch does not enable the setting.
