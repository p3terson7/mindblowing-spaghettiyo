# SAPHIR local-cache deployment

This deployment keeps only a small graphical launcher, `current.json`, and versioned release ZIPs on the shared network folder. Each employee automatically runs the application from `%LOCALAPPDATA%\SAPHIR\versions` while continuing to use the same shared data folder. The launcher itself is also copied to `%LOCALAPPDATA%\SAPHIR\launcher`, so its status window can still open when the deployment share is temporarily unavailable.

## One-time preparation

1. Choose a stable application parent folder, for example `\\server\department\Applications`.
2. Choose the existing shared SAPHIR data folder. A UNC path such as `\\server\department\SAPHIR-Data` is preferred, but a mapped network drive such as R:\SAPHIR-Data is also supported.
3. Open PowerShell in the root of the updated source-code repository on a Windows administrator/deployment workstation, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-app.ps1 `
  -OutputRoot "\\server\department\Applications" `
  -DataFolderPath "\\server\department\SAPHIR-Data" `
  -NoZip
```

This creates the stable employee folder:

```text
\\server\department\Applications\SAPHIR-Distribution
```

The folder contains the graphical launcher, diagnostic launch/stop files, `Install SAPHIR Shortcut.vbs`, the Windows icon, employee guide, release pointer and current release ZIP. It does not contain production data, tests, reset scripts or source-only administration utilities. Employees use this `SAPHIR-Distribution` folder—not the source-code repository.

If your department only exposes a mapped R: drive, use the equivalent command:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-app.ps1 -OutputRoot "R:\Applications" -DataFolderPath "R:\SAPHIR-Data" -NoZip

The publisher first tries to resolve R: to its underlying UNC provider path. If Windows cannot reveal that path but confirms that R: is a network drive, the release keeps the R:\... path and prints a warning. In that fallback case, every employee must have the same R: mapping available when launching SAPHIR.

Use simple folder permissions:

- `SAPHIR-Distribution`: employees receive **Read & execute** only; the person who publishes releases receives **Modify**.
- Existing SAPHIR data folder: employees keep their current **Modify** access under the per-user backend design.

These permissions do not add runtime encryption or expensive security checks. They mainly prevent accidental deletion or replacement of the launcher and release files.

## One-time SAPHIR cutover

`SAPHIR-Distribution` is a new stable folder. Existing Desktop shortcuts do not retarget themselves, so send employees the exact new network path and ask them to run `Install SAPHIR Shortcut.vbs` once. This installs a zero-admin launcher under `%LOCALAPPDATA%\SAPHIR\launcher` and creates the **SAPHIR** Desktop shortcut. The local window opens without synchronously touching the share; network, update and data checks happen in the background. Keep the previous distribution available during the pilot, then archive it according to your normal retention process after everyone has confirmed the new shortcut. Rerun the installer only when the launcher itself changes; ordinary SAPHIR application updates remain automatic.

The launcher uses Windows Script Host, Windows PowerShell 5.1 and WPF already included with supported Windows workstations. It does not require PowerShell 7, .NET SDK, an Internet download, a package manager or administrator rights.

SAPHIR deliberately does not delete the previous local cache during this cutover, so a pilot can still be rolled back safely. That inactive cache consumes disk space only; it does not run and does not slow SAPHIR. It can be removed later through your normal managed workstation cleanup after the rollout is confirmed.

## Publishing an update

Run the same command again from the updated repository. The publisher:

1. creates a new immutable runtime ZIP;
2. computes its SHA-256 checksum;
3. copies the complete ZIP into `deployment\releases`;
4. updates `deployment\current.json` last.

Employees receive the update when they choose **Start SAPHIR** while it is stopped or **Restart** while it is running. Both actions use the versioned cache, checksum validation and automatic rollback workflow. Merely choosing **Open SAPHIR** leaves the healthy backend untouched and does not check the network release. The previous local version remains available for automatic rollback if the new version cannot start.

## Recommended rollout and rollback

For the first deployment and important updates, publish first to a separate pilot parent folder and give that shortcut to one or two employees. After they confirm that sign-in, loading, saving and stopping work from the real Windows shared-drive environment, run the normal production publish command above.

If a production release is bad, restore the last working source-code version or Git commit and run the production publish command again. This publishes the working code under a new release ID and moves everyone forward safely. Do not edit `current.json` by hand. Employees who already have a working local version fall back automatically, but a first-time user needs the corrected release to be published.

## Initial validation

Before giving the shortcut to everyone:

1. Test from an ordinary employee account, not an administrator account.
2. Test from the actual UNC network folder or mapped R: drive used by employees.
3. Run `Install SAPHIR Shortcut.vbs` and confirm that a **SAPHIR** shortcut with the blue logo appears on the Desktop.
4. Confirm that the launcher opens without a console window and displays separate **Application** and **Shared data** states.
5. Confirm that the launcher and icon were copied under `%LOCALAPPDATA%\SAPHIR\launcher` and `%LOCALAPPDATA%\SAPHIR\assets`.
6. With SAPHIR stopped, choose **Start SAPHIR** and confirm that `%LOCALAPPDATA%\SAPHIR\versions\<release>` is created.
7. Confirm that the cached release has no `data` folder and that **Open SAPHIR** opens the browser without changing the backend PID.
8. Confirm that **Stop** removes the managed backend PID and changes the launcher to the offline state.
9. Publish one test update, choose **Start SAPHIR** or **Restart**, and confirm that the backend starts on the new cached version.
10. Disconnect only the deployment share after at least one successful installation. Confirm that the local launcher window still opens and reports the unavailable resource without freezing.
11. Verify that an unrelated process occupying port 8081 is reported as a conflict and is never terminated by the launcher.

This Windows pilot is mandatory: automated tests on another operating system cannot verify your organization’s SMB, antivirus, AppLocker, shortcut and PowerShell 5.1 policies.

## Development-only local packaging

For local tests outside Windows/shared storage, explicitly add `-AllowLocalDataPath`. Never use that switch for the employee distribution.
