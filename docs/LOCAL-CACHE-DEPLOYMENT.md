# GEEM local-cache deployment

This deployment keeps only a tiny launcher, `current.json`, and versioned release ZIPs on the shared network folder. Each employee automatically runs the application from `%LOCALAPPDATA%\OvertimeManager\versions` while continuing to use the same shared data folder.

## One-time preparation

1. Choose a stable application parent folder, for example `\\server\department\Applications`.
2. Choose the existing shared GEEM data folder. A UNC path such as `\\server\department\GEEM-Data` is preferred, but a mapped network drive such as R:\GEEM-Data is also supported.
3. Open PowerShell in the root of the updated source-code repository on a Windows administrator/deployment workstation, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-app.ps1 `
  -OutputRoot "\\server\department\Applications" `
  -DataFolderPath "\\server\department\GEEM-Data" `
  -NoZip
```

This creates the stable employee folder:

```text
\\server\department\Applications\GEEM-Distribution
```

The folder contains the launch/stop files, employee guide, release pointer and current release ZIP. It does not contain production data, tests, reset scripts or source-only administration utilities. Employees use this `GEEM-Distribution` folder—not the source-code repository.

If your department only exposes a mapped R: drive, use the equivalent command:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-app.ps1 -OutputRoot "R:\Applications" -DataFolderPath "R:\GEEM-Data" -NoZip

The publisher first tries to resolve R: to its underlying UNC provider path. If Windows cannot reveal that path but confirms that R: is a network drive, the release keeps the R:\... path and prints a warning. In that fallback case, every employee must have the same R: mapping available when launching GEEM.

Use simple folder permissions:

- `GEEM-Distribution`: employees receive **Read & execute** only; the person who publishes releases receives **Modify**.
- Existing GEEM data folder: employees keep their current **Modify** access under the per-user backend design.

These permissions do not add runtime encryption or expensive security checks. They mainly prevent accidental deletion or replacement of the launcher and release files.

## Publishing an update

Run the same command again from the updated repository. The publisher:

1. creates a new immutable runtime ZIP;
2. computes its SHA-256 checksum;
3. copies the complete ZIP into `deployment\releases`;
4. updates `deployment\current.json` last.

Employees receive the update automatically the next time they launch GEEM. The previous local version remains available for automatic rollback if the new version cannot start.

## Recommended rollout and rollback

For the first deployment and important updates, publish first to a separate pilot parent folder and give that shortcut to one or two employees. After they confirm that sign-in, loading, saving and stopping work from the real Windows shared-drive environment, run the normal production publish command above.

If a production release is bad, restore the last working source-code version or Git commit and run the production publish command again. This publishes the working code under a new release ID and moves everyone forward safely. Do not edit `current.json` by hand. Employees who already have a working local version fall back automatically, but a first-time user needs the corrected release to be published.

## Initial validation

Before giving the shortcut to everyone:

1. Test from an ordinary employee account, not an administrator account.
2. Test from the actual UNC network folder or mapped R: drive used by employees.
3. Confirm that the first launch creates `%LOCALAPPDATA%\OvertimeManager\versions\<release>`.
4. Confirm that the cached release has no `data` folder.
5. Confirm that a second launch does not download the release again.
6. Publish one test update and confirm that the backend restarts on the new cached version.
7. Verify that `Stop GEEM.vbs` stops the cached backend.

This Windows pilot is mandatory: automated tests on another operating system cannot verify your organization’s SMB, antivirus, AppLocker, shortcut and PowerShell 5.1 policies.

## Development-only local packaging

For local tests outside Windows/shared storage, explicitly add `-AllowLocalDataPath`. Never use that switch for the employee distribution.
