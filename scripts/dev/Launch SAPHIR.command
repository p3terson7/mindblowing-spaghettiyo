#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$REPO_ROOT/scripts/launch-cached-app.ps1"
  exit $?
fi

if command -v powershell >/dev/null 2>&1; then
  powershell -NoProfile -File "$REPO_ROOT/scripts/launch-cached-app.ps1"
  exit $?
fi

echo "PowerShell was not found on this machine."
read -r -p "Press Enter to close..."
