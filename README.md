# Overtime Manager

This repository now runs as a single authenticated app:

- one backend: `apps/admin/backend/admin-server.ps1`
- one frontend: `apps/admin/frontend/index.html`
- one shared data store: `data/`

The old employee frontend/backend entrypoints are now compatibility shims:

- `apps/employee/frontend/index.html` redirects to the unified frontend
- `apps/employee/backend/employee-server.ps1` starts the unified backend

The runtime stays compatible with Windows PowerShell 5.1 and also runs on `pwsh` for macOS.

## Project Structure

```text
overtime_manager/
  apps/
    admin/
      backend/
        admin-server.ps1
        admin-config.psd1
        lib/
        services/
        routes/
      frontend/
        index.html
        assets/
        scripts/
    employee/
      backend/
        employee-server.ps1        # compatibility shim
      frontend/
        index.html                 # redirect to unified frontend
        assets/
        scripts/
  data/
    *_data.json
    employeeNames.json
    history.json
    projects.json
    users.json
    sessions.json
    sync-state.json
    .locks/
  docs/
    ARCHITECTURE.md
  scripts/
    start-app.ps1
    stop-app.ps1
    status-app.ps1
    start-all.ps1
    stop-all.ps1
    status-all.ps1
    restart-all.ps1
```

## Quick Start

### Windows PowerShell 5.1

1. Start the backend:
   - `powershell -ExecutionPolicy Bypass -File .\scripts\start-app.ps1`
   - background: `powershell -ExecutionPolicy Bypass -File .\scripts\start-all.ps1`
2. Open the frontend in a browser:
   - `apps/admin/frontend/index.html`
3. Useful commands:
   - stop: `powershell -ExecutionPolicy Bypass -File .\scripts\stop-all.ps1`
   - status: `powershell -ExecutionPolicy Bypass -File .\scripts\status-all.ps1`
   - restart: `powershell -ExecutionPolicy Bypass -File .\scripts\restart-all.ps1`

### macOS / PowerShell 7+

1. Start the backend:
   - `pwsh ./scripts/start-app.ps1`
   - background: `pwsh ./scripts/start-all.ps1`
2. Open the frontend in a browser:
   - `apps/admin/frontend/index.html`
3. Useful commands:
   - stop: `pwsh ./scripts/stop-all.ps1`
   - status: `pwsh ./scripts/status-all.ps1`
   - restart: `pwsh ./scripts/restart-all.ps1`

Legacy commands still work and forward into the merged runtime:

- `start-admin.ps1`
- `start-employee.ps1`
- `stop-admin.ps1`
- `stop-employee.ps1`

## Login

Default bootstrap accounts:

- Admin:
  - username: `admin`
  - password: `ChangeMe123!`
- Employee:
  - username: employee code
  - password: same employee code on first sign-in

The app forces a password change when `mustChangePassword = true`.

Password management in the UI:

- any signed-in user can change their own password from the header
- admins can set or reset employee passwords from the Employees view
- employee resets default to forcing a password change on next sign-in

## Process Management

Managed startup uses:

- `runtime/pids/` for PID files
- `runtime/logs/` for stdout/stderr logs

Recommended commands:

- `start-app.ps1`: run the backend in the current terminal
- `start-all.ps1`: start the backend in the background
- `stop-all.ps1`: stop the managed backend
- `status-all.ps1`: show managed backend status
- `restart-all.ps1`: stop + start

## Unified App Model

Admins and employees now use the same sign-in screen and the same backend.

After sign-in:

- `admin` users see dashboard, employees, logs, and projects
- `employee` users see only their self-service overtime view

This removes duplicated auth/session logic, removes the need for two listener ports in normal use, and keeps role enforcement in the backend where it belongs.

## Multi-User Model

The app supports concurrent use through:

- per-file lock files in `data/.locks`
- atomic JSON writes
- shared auth/session storage
- shared `sync-state.json` for live refresh polling

Recommended deployment model:

- run the unified backend on one shared machine
- point every browser at that backend host
- keep `DataFolderPath` on a shared, access-controlled location

That gives the strongest multi-user file-based setup possible here without introducing a database.

## Configuration

Primary runtime config:

- `apps/admin/backend/admin-config.psd1`

Important settings:

- `ListenerPrefix`: HTTP listener URL prefix
- `DataFolderPath`: path to shared data folder
- `BootstrapAdminUsername`
- `BootstrapAdminPassword`

The frontend also lets users override the API URL at sign-in time.

## Security Notes

- Passwords are hashed with PBKDF2 + per-user salt.
- Session tokens are stored as SHA-256 hashes, not plaintext tokens.
- Overtime/project/history data is still stored as plaintext JSON.
- JSON is not encryption.
- OS/share permissions still matter.
- For network deployment, plain HTTP is still weaker than HTTPS.

Recommended shared-folder deployment:

- do not give regular employees direct write access to the `DataFolderPath`
- run the backend under a dedicated service account
- grant `Modify` only to that service account on both the SMB share and the NTFS folder
- give admins/users access only through the app URL, not through the data share
- if users need the share for other reasons, give them a separate share path that does not expose the JSON store

In practice, the safest model is:

1. one machine runs the PowerShell backend
2. that machine has write access to the shared data folder
3. users access the app over HTTP/HTTPS only
4. users do not browse the JSON files directly

## Legacy Repo Metadata

Previous nested repository metadata was moved to:

- `legacy/git-metadata/admin.git`
- `legacy/git-metadata/employee.git`
