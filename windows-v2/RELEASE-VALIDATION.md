# SafeSync native release validation — 1.0.0-preview.1

2026-10-19. Public Windows preview; version numbering replaces the internal 2.0.0-preview series. This is not a stable-release or OAuth production-approval claim. macOS is unchanged.

## Current release candidate

| Gate | Evidence/status |
| --- | --- |
| Core regression and fault injection | 448 assertions passed; includes two-way local, mocked Google/Dropbox, corrupted download preservation and retry |
| Native UI and exit | 316 assertions passed with bundled runtime; no PowerShell loaded |
| Installer rollback, upgrade, uninstall | 33 assertions passed; 498 real payload file SHA-256 values matched in an isolated installation |
| Real Google two-way sync | 35 checks passed in a newly created test folder; original account configuration unchanged |
| Real Dropbox OAuth and two-way sync | User-approved browser OAuth completed; 32 checks passed in a newly created test folder |
| Real NAS two-way sync | 22 stages passed, 11 per endpoint direction, in the user-authorized empty test area |
| Dropbox public registration | SafeSync Personal, full Dropbox, minimal scopes, loopback callback, developer users, branding and public policy configured; Production approval not yet granted |
| Signing / Google approval / Dropbox production approval | Not completed; do not advertise as approved |
| Clean Windows, multi-day operation, physical outages | Still not completed |

NAS root identity initially included creation time, but the real Samba server changed it after directory mutations. It now prefers volume/file ID; both directions passed after correction. Unavailable or replaced roots still stop deletion propagation. Empty-folder creation and implicit parents are checkpointed correctly.

Two-way first execution unions unique items and flags divergent content. Subsequent changes use the last common successful baseline. Backup deletion can delete source content into its own SafeSync trash. Offline or inaccessible roots are not interpreted as mass deletion. Run on test data and keep an independent backup.

For current behavior and API scope limitations see [TWOWAY-AND-DROPBOX.md](TWOWAY-AND-DROPBOX.md); current evidence is in [TEST-RESULTS.md](TEST-RESULTS.md). Tests and real credentials remain excluded from public binaries; source tests contain no credentials. Production request instructions are in [DROPBOX-PRODUCTION.md](DROPBOX-PRODUCTION.md).

The following sections are historical evidence for internal preview.9, not current missing Dropbox test results.

---

## Internal preview.9 validation history

This is a validation build, not a declaration that all release gates passed.
Public/commercial distribution (signing, OAuth approval, legal/support material)
is excluded from this task. Existing 1.x installations and user data remain unchanged.

## Scope and isolation

- Synthetic regression fixtures: `artifacts/tests/` (preserved for diagnosis).
- Installer tests: `artifacts/packaging-*/setup-*`; real registry/shortcuts untouched.
- NAS: user-authorized `\\192.168.50.1\Media\test\SafeSync-validation-*` only.
- Never disconnect the user's network or power-cycle their NAS during testing.
- Google tests used the existing account in memory and newly created dedicated folders; account config/old backups stayed unchanged. Dropbox is not live-tested.

## Changes under verification

- Bounded read/request-limit retries with jitter and Retry-After; permission
  failures are not mistaken for rate limits. Ambiguous mutations are not replayed.
- Native delta checkpoints are included when importing a native snapshot.
- Obsolete extension Generation fields cannot override a new snapshot generation.
- Native per-user installer/uninstaller, bundled runtime, file checksums,
  journaled update/rollback, preservation of unknown files and separate data roots.
- Installer requests graceful shutdown via a current-user-only control channel;
  failure to stop aborts the update without force-killing a backup.
- Tests include real child process termination at installation boundaries.

## Release gates

| Gate | Evidence/status |
| --- | --- |
| Core regression and fault injection | 280 assertions passed; local/mocked cloud |
| Native UI, light/dark, window exit | 312 assertions passed, including an isolated installed bundle |
| NAS upload/download, replace, lock, trash/restore | 22 NAS-specific assertions passed in the user-selected test root |
| Installer upgrade/rollback/uninstall | 33 assertions passed; preview.9 full payload installed with 497 hashes matched, installed-app UI smoke and removal passed |
| Real Google Drive account behavior | 52 scenario checks + 6 targeted restart checks passed; final preview.9 full scenario repeat passed, see GOOGLE-LIVE-RESULTS.md |
| Real Dropbox account behavior | Not tested; no Dropbox test selected |
| Physical network/power interruption | Not performed; path-unavailable tests are not equivalent |
| Clean Windows 10/11 installation, registry/startup | Not tested on a clean machine |
| Multiple days of continuous execution, sleep/reboot, DPI/monitors | Not completed by short automated tests |

Formal release remains conditional on the untested gates above. SQLite or more
parallelism is optional and does not replace these safety gates.

## NAS evidence

Preserved fixture:
`\\192.168.50.1\Media\test\SafeSync-validation-9c174540b6e84a82a0d17ef1c0800897`

Local result: `artifacts/tests/safesync-v2-46e1bcc7c128412b9a9531ada0afb5f3/nas-result.json`.
Each direction used 123 files (120 text files, one long Unicode/emoji path,
one empty file, and one 32 MiB + 17-byte binary). The replacement operation
worked on this particular NAS. No fallback to truncating an existing file was used.

| Direction | Initial backup | Unchanged full metadata comparison | One-file incremental replacement |
| --- | ---: | ---: | ---: |
| Local to NAS | 16.190 s | 1.084 s | 0.253 s |
| NAS to local | 7.262 s | 1.389 s | 0.099 s |

These are single-run small-fixture measurements, not a GoodSync benchmark or
a prediction for large libraries. Temporary unavailability was tested only by
renaming our own endpoint and restoring its name. No physical disconnection,
power failure, quota exhaustion, or user account permission changes were performed.
Test files are intentionally left available for inspection.

## Short stress test

`artifacts/tests/safesync-v2-c5c490278b7f4570bab2552ae95c3f84/stress-result.json`:
200 cycles over 500 files, 121.7 seconds, 939 assertions including 500 final
SHA-256 comparisons. Pause/resume, fresh engine/state loads, deletion to trash,
and a real copy-worker process termination/retry passed. Working set started
at 50,626,560 bytes, peaked at 69,816,320, and ended at 62,259,200.
This is not a multi-day soak test or proof of absence of memory leaks.

## Installer isolation and prerequisites

The bootstrapper uses Windows .NET Framework 4.8; the app carries its own
.NET 10 desktop runtime. Real registry/Start Menu/auto-start and clean-machine
tests remain open. The installation is side-by-side in `Programs/SafeSync2`
and retains the preview data root. Updates are manually initiated by rerunning
the installer, not downloaded automatically. Uninstall preserves settings,
snapshots, backup files and a tiny install receipt/inventory for repair.

The full payload is actually installed into a generated test root, hash-checked,
run with `--smoke-test` and an isolated data root, and then removed. These tests
never register a real installation or use existing accounts.

An SDK first-run invocation unexpectedly created one localhost ASP.NET HTTPS
development certificate. It was identified by its creation time and thumbprint
and only that generated certificate/key was removed. No existing certificates
were removed; this was unrelated to code signing. Later builds isolate SDK state.

## Retry design references

- [Google Drive error handling](https://developers.google.com/workspace/drive/api/guides/handle-errors)
- [Google Drive resumable-upload recovery](https://developers.google.com/workspace/drive/api/guides/manage-uploads)
- [Dropbox error handling](https://developers.dropbox.com/en-us/error-handling-guide)
- [Microsoft Framework long-path behavior](https://learn.microsoft.com/en-us/dotnet/framework/migration-guide/retargeting/4.6.x)
