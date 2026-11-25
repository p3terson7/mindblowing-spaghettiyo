#!/bin/sh
set -eu
cd "$(dirname "$0")"
for powershell in /opt/homebrew/bin/pwsh /usr/local/bin/pwsh pwsh; do
  if command -v "$powershell" >/dev/null 2>&1; then
    exec "$powershell" -NoLogo -NoProfile -File ./Start-demo.ps1 "$@"
  fi
done
printf '%s\n' 'PowerShell 7 (pwsh) est requis pour lancer SAPHIR sur macOS.' >&2
exit 1
