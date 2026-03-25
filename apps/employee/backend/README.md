# Employee Backend Layout

The employee backend now mirrors the admin backend's runtime model while staying PowerShell 5.1 compatible.

## Entry Point

- `employee-server.ps1`
  - Loads employee context.
  - Reuses the shared file-locking, auth, sync, and self-service routes from the admin backend.
  - Starts a local `HttpListener` for the employee UI.

## Context

- `lib/EmployeeContext.ps1`
  - Resolves config and shared data paths.
  - Initializes the shared JSON files needed by both apps.

## Shared Runtime

This backend intentionally reuses the admin backend's shared scripts for:

- password hashing and session tokens
- file locking and atomic JSON writes
- sync-state publishing for live refresh
- `/auth/*`, `/sync/status`, and `/self/*` endpoints

That keeps employee and admin behavior aligned while avoiding a second monolithic backend script.
