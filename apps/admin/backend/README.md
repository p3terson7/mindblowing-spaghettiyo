# Unified Backend Layout

This folder now contains the single backend used by both admins and employees.

The backend is split into focused scripts to keep PowerShell 5.1 compatibility while improving maintainability.

## Entry Point

- `admin-server.ps1`
  - Bootstraps context/helpers/services.
  - Starts `HttpListener`.
  - Dispatches request handling through route files.

## Context + Helpers

- `lib/AdminContext.ps1`
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
