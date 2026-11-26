$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $scriptRoot -ChildPath "../lib/TestPowerShellRuntime.ps1")
$tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("saphir-file-store-multiprocess-{0}" -f ([Guid]::NewGuid().ToString("N")))
$dataRoot = Join-Path -Path $tempRoot -ChildPath "data"
$recordsPath = Join-Path -Path $dataRoot -ChildPath "records.json"
$workerPath = Join-Path -Path $tempRoot -ChildPath "worker.ps1"
$startMarker = Join-Path -Path $tempRoot -ChildPath "start.marker"
$workerCount = 4
$recordsPerWorker = 20
$processes = New-Object System.Collections.ArrayList

try {
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    [IO.File]::WriteAllText($recordsPath, "[]", (New-Object Text.UTF8Encoding($false)))

    $workerScript = @'
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$DataRoot,
    [Parameter(Mandatory = $true)][string]$RecordsPath,
    [Parameter(Mandatory = $true)][string]$StartMarker,
    [Parameter(Mandatory = $true)][int]$WorkerId,
    [Parameter(Mandatory = $true)][int]$RecordCount
)

$ErrorActionPreference = "Stop"
$script:sharedFolder = $DataRoot
$script:lockFolder = Join-Path -Path $DataRoot -ChildPath ".locks"
. (Join-Path -Path $RepositoryRoot -ChildPath "app/backend/lib/FileStore.ps1")

# Deliberately warm a stale snapshot before every process starts writing. A
# correct lock transaction must invalidate this process-local cache after it
# acquires the shared lock.
@(Read-JsonArrayFile -Path $RecordsPath) | Out-Null
$readyPath = Join-Path -Path (Split-Path -Path $StartMarker -Parent) -ChildPath ("ready-{0}" -f $WorkerId)
$runtimeDescriptor = "{0}|{1}" -f ([string]$PSVersionTable.PSEdition), $PSVersionTable.PSVersion.ToString()
[IO.File]::WriteAllText($readyPath, $runtimeDescriptor)

$deadline = (Get-Date).AddSeconds(15)
while (-not (Test-Path -LiteralPath $StartMarker -PathType Leaf)) {
    if ((Get-Date) -ge $deadline) {
        throw "Timed out waiting for the multiprocess start marker."
    }
    Start-Sleep -Milliseconds 20
}

for ($index = 0; $index -lt $RecordCount; $index++) {
    $lockHandle = Acquire-ResourceLock -ResourcePath $RecordsPath
    try {
        $records = @(Read-JsonArrayFile -Path $RecordsPath)
        $records += [PSCustomObject]@{
            id       = "{0}-{1}" -f $WorkerId, $index
            workerId = $WorkerId
            index    = $index
        }
        Write-JsonArrayAtomic -Path $RecordsPath -Items $records -Depth 4
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}
'@
    [IO.File]::WriteAllText($workerPath, $workerScript, (New-Object Text.UTF8Encoding($false)))

    $powerShellPath = Get-TestPowerShellExecutable
    for ($workerId = 1; $workerId -le $workerCount; $workerId++) {
        $stdoutPath = Join-Path -Path $tempRoot -ChildPath ("worker-{0}.stdout.log" -f $workerId)
        $stderrPath = Join-Path -Path $tempRoot -ChildPath ("worker-{0}.stderr.log" -f $workerId)
        $process = Start-Process -FilePath $powerShellPath `
            -ArgumentList @(
                "-NoProfile",
                "-File", $workerPath,
                "-RepositoryRoot", $repoRoot,
                "-DataRoot", $dataRoot,
                "-RecordsPath", $recordsPath,
                "-StartMarker", $startMarker,
                "-WorkerId", $workerId,
                "-RecordCount", $recordsPerWorker
            ) `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
        [void]$processes.Add([PSCustomObject]@{
            Process    = $process
            WorkerId   = $workerId
            StderrPath = $stderrPath
        })
    }

    $readyDeadline = (Get-Date).AddSeconds(15)
    while (@(Get-ChildItem -LiteralPath $tempRoot -Filter "ready-*" -File -ErrorAction SilentlyContinue).Count -lt $workerCount) {
        if ((Get-Date) -ge $readyDeadline) {
            throw "Workers did not reach the multiprocess start barrier."
        }
        foreach ($worker in @($processes.ToArray())) {
            if ($worker.Process.HasExited -and $worker.Process.ExitCode -ne 0) {
                $stderrText = if (Test-Path -LiteralPath $worker.StderrPath) { [IO.File]::ReadAllText($worker.StderrPath) } else { "" }
                throw "Worker $($worker.WorkerId) exited before the barrier. $stderrText"
            }
        }
        Start-Sleep -Milliseconds 20
    }
    $expectedRuntimeDescriptor = "{0}|{1}" -f ([string]$PSVersionTable.PSEdition), $PSVersionTable.PSVersion.ToString()
    for ($workerId = 1; $workerId -le $workerCount; $workerId++) {
        $readyPath = Join-Path -Path $tempRoot -ChildPath ("ready-{0}" -f $workerId)
        $actualRuntimeDescriptor = [IO.File]::ReadAllText($readyPath)
        Assert-True `
            -Condition ($actualRuntimeDescriptor -eq $expectedRuntimeDescriptor) `
            -Message "Worker $workerId used PowerShell '$actualRuntimeDescriptor' instead of the parent runtime '$expectedRuntimeDescriptor'."
    }
    [IO.File]::WriteAllText($startMarker, "start")

    foreach ($worker in @($processes.ToArray())) {
        Assert-True -Condition ($worker.Process.WaitForExit(30000)) -Message "Worker $($worker.WorkerId) timed out."
        if ($worker.Process.ExitCode -ne 0) {
            $stderrText = if (Test-Path -LiteralPath $worker.StderrPath) { [IO.File]::ReadAllText($worker.StderrPath) } else { "" }
            throw "Worker $($worker.WorkerId) failed with exit code $($worker.Process.ExitCode). $stderrText"
        }
    }

    $savedText = [IO.File]::ReadAllText($recordsPath)
    Assert-True -Condition $savedText.TrimStart().StartsWith("[") -Message "Multiprocess writes changed the collection root away from an array."
    $records = @($savedText | ConvertFrom-Json -ErrorAction Stop)
    $expectedCount = $workerCount * $recordsPerWorker
    Assert-True -Condition ($records.Count -eq $expectedCount) -Message "Lost update detected: expected $expectedCount records, found $($records.Count)."
    $uniqueIds = @($records | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
    Assert-True -Condition ($uniqueIds.Count -eq $expectedCount) -Message "Duplicate or missing record IDs were found after concurrent writes."
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $dataRoot -Filter "*.tmp.*" -File -ErrorAction SilentlyContinue).Count -eq 0) -Message "Atomic writes left temporary files behind."
    Assert-True -Condition (@(Get-ChildItem -LiteralPath (Join-Path -Path $dataRoot -ChildPath ".locks") -Filter "*.lock" -File -ErrorAction SilentlyContinue).Count -eq 0) -Message "Completed writers left lock files behind."

    Write-Host "File-store multiprocess test passed: $expectedCount concurrent read-modify-write commits were preserved."
}
finally {
    foreach ($worker in @($processes.ToArray())) {
        if ($null -ne $worker.Process -and -not $worker.Process.HasExited) {
            Stop-Process -Id $worker.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
