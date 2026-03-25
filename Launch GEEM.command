#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$REPO_ROOT/scripts/launch-app.ps1"
  exit $?
fi

if command -v powershell >/dev/null 2>&1; then
  powershell -NoProfile -File "$REPO_ROOT/scripts/launch-app.ps1"
  exit $?
fi

echo "PowerShell was not found on this machine."
read -r -p "Press Enter to close..."
