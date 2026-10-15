# Deploy a downloaded ZIP from Desktop

One-time setup:

1. Copy `scripts/deploy-downloaded-zip.ps1` and `scripts/Deploy SAPHIR.bat` to your work PC's Desktop, beside each other. These two files are standalone; keep them there for future updates.
2. Open the `.ps1` file in a text editor. Fill in `OutputRoot` and `DataFolderPath` in the `Configuration` section near the top:

```powershell
OutputRoot = 'R:\SAPHIR\deployed'
DataFolderPath = 'R:\SAPHIR\DATA'
```

Use your actual existing deployment and DATA paths. `OutputRoot` is the **parent** of `SAPHIR-Distribution`. For example, if employees currently use `R:\SAPHIR\deployed\SAPHIR-Distribution`, configure `R:\SAPHIR\deployed`. Keep this path stable so existing employee shortcuts continue to work. A shared UNC path is preferable when available.

The script defaults to your profile's Downloads folder and the ZIP pattern `mindblowing-spaghettiyo-codex-windows-launcher*.zip`. Adjust these two settings if needed. Browser duplicate names such as `... (1).zip` are supported. Save the script as UTF-8 **with BOM** if your edited paths contain accents and you use Windows PowerShell 5.1.

## Each update

1. Download the trusted code ZIP from GitHub into the configured Downloads folder. Wait for the download to finish.
2. Double-click **Deploy SAPHIR.bat** on Desktop. It selects the newest matching `.zip`, displays its path/hash and your deployment/DATA paths, and publishes the full release. The window stays open so errors remain readable.

You no longer need to extract on Desktop, rename repository/app folders, delete GitHub files, copy source folders over SMB, open a terminal in the repository, or enter the packaging arguments manually.

The script extracts locally, ignores root GitHub metadata and repository DATA, invokes **the downloaded version's** `scripts/package-app.ps1`, and publishes to the stable `SAPHIR-Distribution`. There is no random source-code directory on the shared drive. Every run creates a unique release ID. It is always a **full application release**, never `-BootstrapOnly`. It omits the optional outer distribution ZIP, not the application release ZIP needed by the launcher.

Existing employee shortcuts remain valid. Users pick up the update on the next normal SAPHIR restart; running backends are not forcibly stopped.

## Preview / choose an exact ZIP

From PowerShell in your Desktop folder:

```powershell
.\deploy-downloaded-zip.ps1 -WhatIf
.\deploy-downloaded-zip.ps1 -ZipPath 'C:\Users\YOUR-ID\Downloads\downloaded-code.zip'
```

Preview validates archive structure and displays the selected paths without extracting or publishing anything. To use a different destination temporarily, explicit `-OutputRoot` and `-DataFolderPath` arguments override your saved settings. `-AllowLocalDataPath` exists for isolated local tests only; production keeps the existing packager's shared-DATA checks.

## Safety / troubleshooting

- Existing DATA is never migrated, reset, deleted or copied into the release. **The compensation backfill is not run automatically.** Its offline procedure remains separate: see [COMPENSATION-BACKFILL.md](COMPENSATION-BACKFILL.md).
- The downloaded ZIP is retained unchanged. Its SHA-256 is displayed for identification, not presented as a GitHub signature or authenticity proof. Deploy only a trusted download from the correct repository/branch.
- Extraction rejects path traversal, absolute paths, Windows device/stream names, links, duplicate paths, oversized archives and ambiguous repositories. It never executes an arbitrary first `.ps1` found in the ZIP.
- The existing packager verifies the release ZIP on the share and publishes `current.json` last. A build failure before publication leaves the previous release pointer/package unchanged. A network failure during publication can have an ambiguous outcome: read the error and inspect `deployment/current.json` before retrying. This is not a whole-directory transactional swap of every launcher file.
- Existing release retention remains the packager's policy: current release plus two rollback packages. No new cleanup of shared/source/DATA folders is added.
- Successful local staging is removed. Failed staging is retained at the exact temporary path shown in the console for troubleshooting. The script never recursively removes Desktop, Downloads, DATA or the shared deployment root.
- This does not disable antivirus, unblock downloaded files, elevate privileges or use execution-policy bypass. The small `.bat` uses Windows PowerShell with `RemoteSigned`. If your organization blocks execution, use its approved signing/trust process or contact IT instead of weakening the policy.

Test coverage: isolated synthetic DATA, standalone Desktop configuration, latest ZIP selection, read-only preview, a real packaged release and launcher pointer, unchanged DATA/download, failed builds, dangerous archive paths and stable destination checks. Windows execution-policy/SMB behavior still needs verification on the work PC.
