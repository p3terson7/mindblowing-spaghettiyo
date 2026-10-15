# Save amounts on older entries

`scripts/backfill-compensation.ps1` fills in missing monetary snapshots on approved overtime entries. It uses the current employee classification, the DATA salary grid, and SAPHIR's existing calculation rules. This is an administrator maintenance operation, not an automatic startup migration.

## 1. Preview

From the deployed `SAPHIR-Distribution` folder, run:

```powershell
.\scripts\backfill-compensation.ps1
```

The deployed wrapper uses the current published release, verifies/extracts it into the local application cache if needed, and reads the DATA path from the deployment manifest. It does not start SAPHIR. After stopping SAPHIR on every computer, apply with `.\scripts\backfill-compensation.ps1 -Apply -AppStopped`. A full release is required to publish the migration code; BootstrapOnly is not enough when upgrading from a release without it. The guide is also published under `tools/COMPENSATION-BACKFILL.md`.

Run from the repository or an extracted application release (the directory containing `app` and `scripts`). Replace the example DATA path with the actual shared DATA folder:

```powershell
$report = .\scripts\backfill-compensation.ps1 -DataFolder 'R:\SAPHIR\DATA'
$report
$report.issues | Format-Table file, entryIndex, entryId, reason -AutoSize
```

Preview does not write to DATA, create backups or acquire/create locks. It does not create missing users, salary grids or defaults. A malformed employee file blocks the entire operation before any employee writes. Missing salary/classification/schedule information is reported; apply stores an explicit unavailable result (N/A), never zero dollars. The salary grid itself must be readable and valid before this maintenance operation starts.

## 2. Stop SAPHIR everywhere, then apply

Use **Stop SAPHIR** on every computer using this DATA folder. Closing a browser tab is not enough: stop the backends too. Keep the app stopped until the migration finishes. `-AppStopped` is your explicit acknowledgement; the script cannot discover remote corporate workstations.

```powershell
$report = .\scripts\backfill-compensation.ps1 -DataFolder 'R:\SAPHIR\DATA' -Apply -AppStopped
$report
$report.issues | Format-Table file, entryIndex, entryId, reason -AutoSize
```

If the script is elsewhere, specify `-ApplicationRoot 'C:\path\to\release\app'`. Do not point it at a different release's calculation code unintentionally.

Restart SAPHIR normally on each computer afterward. No sync-state rewrite is performed: this offline procedure starts every backend with empty caches. Do not use it while any backend remains running.

## What it changes

- Only adds/replaces `compensationSnapshot` on approved overtime entries: either a calculated amount or an explicit unavailable result with its reason and null amount.
- Preserves existing final snapshots, pending/rejected entries, `diverse` entries, comments, names, dates, IDs, custom fields and entry order.
- Uses the whole employee document to calculate daily thresholds and adjacent-day rules; cash and compensatory leave retain their different amounts.
- Splices the new snapshot into the original JSON instead of reserializing all entry fields. Unknown nested fields, timestamp strings and large number literals retain their exact text. Changed files are UTF-8 without a BOM; backup bytes preserve the original encoding/BOM.
- Does not merge files, delete entries, rewrite profiles/salaries, or delete backups. Existing final snapshots remain authoritative.

## Normal operation after migration

There is no read-time salary fallback. Personnel, Projects, Review and reports read the saved result and aggregate available amounts. Missing/unavailable amounts show N/A with an explanatory reason and are excluded from money totals; partial coverage remains visible. Unmigrated entries also show N/A (`snapshot-missing`), without an implicit calculation or write.

Saving an employee's GC179 classification (including echelon) retries that employee's missing/unavailable results and persists successful ones. Entry edits, approval/import and monthly schedule confirmation use the same write-time calculator; deleting an entry recalculates affected employee history for daily/adjacent-day rules. A global compressed-workweek preference applies to new entries, not ambiguous historical schedules: confirm those on the entry or with the monthly bulk action.

A salary-grid save retries missing/unavailable results across employee files as a settings-write operation, not during view loading. Already final amounts keep their captured salary and are not repriced by profile/grid changes. Per-employee revisions are published for changed files. If a post-save refresh fails, the settings response reports a warning; fix the issue and save that employee's classification again to retry. No background or view-load retry is introduced.

Run this migration while all backends are stopped before users start the new version. Both calculable and N/A rows can be migrated in one pass, so incomplete employee profiles do not block the transition. Repeated runs preserve both stable amounts and stable N/A results.

## Backup and failure behavior

Before the first employee write, a unique folder is created under:

```text
DATA/.saphir-backups/compensation-<timestamp>-<unique-id>/
```

It contains byte-for-byte copies of all enumerated numeric `*_data.json` files, `users.json`, `compensation-grid.json`, and a SHA-256 manifest. This is a backup of migration inputs, not a full backup of all application data. It includes sensitive information: restrict access like DATA and retain it somewhere protected.

Each write holds the normal employee lock, verifies that the employee file and salary inputs still match preflight, writes and verifies a separate staging file, then uses atomic `File.Replace`. The saved bytes are checked afterward. A per-file completion receipt is kept beside the backups.

There is **no delete-and-copy or non-atomic overwrite fallback**. If the SMB filesystem does not support the atomic operation, the script stops and retains backups/staging files. Do not work around that failure by deleting the original file.

Atomicity is **per employee file**, not across all employees. If interrupted, some complete files may already be migrated and others not. Keep SAPHIR stopped and rerun preview/apply: completed amounts are skipped. An interruption after replacement but before a completion receipt is also safe to resume; saved snapshots, not receipts, determine what remains.

If a source file changes unexpectedly, or verification fails, stop and inspect the affected original, manifest and backup. No automatic rollback is attempted, because restoring an old backup could overwrite legitimate newer work. For manual recovery, keep every backend stopped, preserve a copy of the current file, verify the backup hash against `manifest.json`, and restore only the affected file after reviewing it. Never copy an entire old DATA backup over newer production data.

## Tests

```powershell
pwsh -NoProfile -File tests/powershell/test-compensation-backfill.ps1
```

Tests use isolated synthetic DATA, not the working or shared production folder. They cover fresh-process read-only preview, malformed/ambiguous input, byte-identical backups, backup/atomic-write failure, concurrent source changes, interruption/resume, saved amounts, custom-field preservation, daily thresholds, compensatory leave, unavailable entries and repeated runs. Windows PowerShell 5.1 is supported by the script; Windows/SMB runtime behavior still needs verification on the target network.
