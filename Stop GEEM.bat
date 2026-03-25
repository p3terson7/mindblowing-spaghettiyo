@echo off
setlocal
set "REPO_ROOT=%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%scripts\stop-all.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%scripts\stop-all.ps1"
)

if errorlevel 1 pause
