# Unified Backend Layout

This folder now contains the single backend used by both admins and employees.

The backend is split into focused scripts to keep PowerShell 5.1 compatibility while improving maintainability.

## Entry Point

- `saphir-server.ps1`
  - Bootstraps context/helpers/services.
  - Starts `HttpListener`.
  - Dispatches request handling through route files.
- `saphir-config.psd1`
  - Defines the listener and DATA location for this runtime.

The matching browser application is `../frontend/index.html`. Both role groups
use this same backend and frontend; authorization remains a server-side rule,
not a separate application tree.

## Context + Helpers

- `lib/AppContext.ps1`
  - Loads config, resolves shared data paths, initializes baseline data files.
- `lib/CommonHelpers.ps1`
  - Shared helper functions (`Get-EmployeeName`, `Format-TimeForHistory`).
- `lib/ResponseHelpers.ps1`
  - JSON success/error response writers.
- `lib/FileStore.ps1`
  - Atomic JSON writes and file-based locking.

## Services

- `services/HistoryService.ps1`
  - History append logic.
- `services/AuthService.ps1`
  - PBKDF2 password hashing, bearer sessions, and password updates.
- `services/SyncService.ps1`
  - Shared sync-state version publishing for live refresh.
- `services/ProjectStatsService.ps1`
  - Shared project statistics aggregator.

## Routes

- `routes/auth.routes.ps1`
- `routes/sync.routes.ps1`
- `routes/self.routes.ps1`
- `routes/history.routes.ps1`
- `routes/employee.routes.ps1`
  - Aggregates endpoint route scripts under `routes/employee/`, including employee password reset.
- `routes/project.routes.ps1`
  - Aggregates endpoint route scripts under `routes/projects/`.
- `routes/project-stats.routes.ps1`
  - Aggregates endpoint route scripts under `routes/stats/`.

Subfolders (`routes/employee`, `routes/projects`, `routes/stats`) keep one endpoint block per file for easier edits and safer reviews.

## Legacy release compatibility

New code and release packages must use this `app/backend` tree. The launcher’s
layout resolver also understands the former release layout solely so an already
cached version can be selected during rollback. Do not add new code or
deployment instructions to that historical tree.
