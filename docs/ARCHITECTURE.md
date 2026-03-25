# Architecture Overview

## Runtime Components

- Unified backend: `apps/admin/backend/admin-server.ps1`
  - Default listener: `http://localhost:8081/`
  - Handles auth, sessions, employee self-service routes, admin routes, and shared sync state.
- Unified frontend: `apps/admin/frontend/index.html`
  - Single sign-in screen for both roles.
  - Switches the visible UI by authenticated role.
- Legacy compatibility entrypoints:
  - `apps/employee/frontend/index.html` redirects to the unified frontend.
  - `apps/employee/backend/employee-server.ps1` forwards to the unified backend.

## Role Model

- `admin`
  - Dashboard
  - Employee management
  - Approval/history views
  - Project analytics
  - Employee password reset tools
- `employee`
  - Self-service overtime entries
  - Punch in/out
  - Personal approval status
  - Self-service password change

The browser only changes what it renders. The backend remains the real security boundary and enforces role-based access on protected routes.

## Storage Model

- Shared JSON folder: `data/`
- Files include:
  - `*_data.json`: employee overtime entries
  - `employeeNames.json`: employee code/name mapping
  - `projects.json`: project catalog
  - `history.json`: admin action history
  - `users.json`: password-hash based user records
  - `sessions.json`: active bearer sessions (token hashes only)
  - `sync-state.json`: shared version marker used for live refresh
  - `.locks/`: per-resource file locks for concurrent writes

The unified backend points to that folder through `DataFolderPath` in `apps/admin/backend/admin-config.psd1`.

## Concurrency Strategy

- Reads happen against complete JSON documents.
- Writes are serialized with per-file lock files.
- JSON updates are written atomically through temp-file replacement.
- Every successful data mutation publishes a new sync version so other clients can refresh.

This gives reliable multi-user coordination with only PowerShell, files, and JSON.

## Authentication Strategy

- Passwords are hashed with PBKDF2 + per-user salt.
- Session tokens are random bearer tokens, but only their SHA-256 hashes are stored on disk.
- First-login password changes are enforced with `mustChangePassword`.
- The frontend stores only the bearer token and user profile in browser storage.

This is a meaningful security upgrade, but the underlying business data files are still plaintext and should be protected with OS/share permissions.

## Live Update Strategy

- The backend increments `sync-state.json` when tracked data changes.
- The frontend polls `/sync/status` on an interval.
- If the version changes, the active role-specific view refreshes automatically.

That gives practical live updates without adding websockets or external infrastructure.

## Compatibility Notes

- Implementation remains Windows PowerShell 5.1 compatible.
- The same scripts also run on `pwsh` on macOS.
- Startup scripts now target one managed backend instead of two separate services.
