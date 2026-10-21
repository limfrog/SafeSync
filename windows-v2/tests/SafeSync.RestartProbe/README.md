# Windows restart reproduction

This is a diagnostic test of the unchanged Windows preview.14 production `SafeSync.Core` and `BackupScheduler`. It does not change synchronization decisions, installers, the update feed or the website. Baseline source commit: `bfca3da53ce5bc81e02fe2c538e3277f33c0cb14`.

The `Windows restart reproduction` GitHub workflow runs on Windows Server 2022 and 2025 hosted runners. It creates an isolated NTFS virtual disk with a USN journal and a loopback SMB share. It does not connect to the owner's PC, NAS or cloud accounts and uses no account secrets.

## Method

- Five fixtures: NTFS one-way/two-way, SMB source one-way, SMB destination one-way/two-way.
- Each has 256 synthetic small files across eight folders plus a 4 MiB file.
- Each automatic startup uses a new real child process, the same saved job/snapshot and the desktop's production `SetJobs` / `Start` scheduler path. This is not just constructing a second engine in one process.
- Two unchanged restarts check copying, deletion, contents, file IDs, modification times, pending paths and active-checkpoint state.
- With workers fully exited, the controller adds, modifies, renames and deletes source files. No changed-path list is supplied to the scheduler. Two-way fixtures also change the backup side while offline.
- Another unchanged restart checks repeat transfers after offline recovery.
- A same-length, restored-creation/modification-time edit must either sync or produce an explicit file conflict. Silently skipping different bytes is a failure. One-way equal-time conflicts must remain pending for user review.
- A separate process is killed after the production engine persists a five-file checkpoint. A fresh scheduler must finish the remaining files without replacing already completed copies.
- A read-only native diagnostic records journal query/read success and Windows error codes, comparing production access flags with a separate generic-read handle for diagnosis. It never changes production permissions or retries on behalf of the engine.

## Interpretation

Correctness checks fail the workflow. Performance is reported separately, not hidden by a green check: full-folder scans, unique compared paths, explicit one-way content-hash progress stages, copied/skipped/trashed counts and elapsed run time are recorded in `summary.json` and `summary.md`.

`Copied=0` does **not** mean no full rescan or content reads. `ContentVerificationPaths=0` in two-way mode does **not** mean hashes were not read, because that engine does not emit the same content-hash stage. Elapsed run time includes the scheduler's initial timer wait; it is not a throughput benchmark. Exact disk read bytes and network transfer bytes are not instrumented.

The report's full-scan conditions are observations of persisted state and a read-only preflight, not a new production reason-reporting feature. The production stage events show whether a full scan actually happened.

## Not covered

- WPF desktop startup/shutdown, tray menus and visual interaction.
- Windows machine reboot or power loss in the middle of an individual file transfer.
- Windows 10/11 client-specific behavior (the hosted images are Windows Server).
- The owner's physical NAS, Samba implementation, WAN latency or real Google Drive/Dropbox APIs.

The checkpoint kill is deterministic and narrow; it must not be described as a complete mid-transfer crash test. SMB loopback findings must not be described as testing the actual NAS.

Workflow artifacts contain only generated test files/settings and are retained for seven days. No installer or public download is updated by this workflow.
