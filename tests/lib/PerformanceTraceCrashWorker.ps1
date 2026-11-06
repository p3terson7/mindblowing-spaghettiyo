param([string]$BackendRoot)
$ErrorActionPreference = "Stop"
. (Join-Path $BackendRoot "lib/PerformanceTrace.ps1")
Start-SaphirPerformanceTrace "interrupted-workflow"
$frame = Start-SaphirPerformanceSpan -Name "Blocked.Operation" -Component "Test" -Type "workflow"
# Owned subprocess used to prove that the writer flushes while PowerShell is
# blocked; the parent terminates this process, never a real application.
[Threading.Thread]::Sleep(30000)
Stop-SaphirPerformanceSpan $frame
Stop-SaphirPerformanceTrace 200
Close-SaphirPerformanceWriter
