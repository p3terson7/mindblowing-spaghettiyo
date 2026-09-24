$ErrorActionPreference = "Stop"

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-budget-service-{0}" -f [Guid]::NewGuid().ToString("N"))
$script:budgetPeriodsFile = Join-Path -Path $tempRoot -ChildPath "budget-periods.json"
$script:writeCount = 0
$script:clearCount = 0

function Read-TextFileCached {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

function Clear-CachedFileContent {
    param([string]$Path)
    $script:clearCount++
}

function Acquire-ResourceLock {
    param([string]$ResourcePath)
    return [PSCustomObject]@{ path = $ResourcePath }
}

function Release-ResourceLock {
    param($LockHandle)
}

function Write-JsonAtomic {
    param([string]$Path, $Value, [int]$Depth)
    $script:writeCount++
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth $Depth), (New-Object System.Text.UTF8Encoding($false)))
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath "app/backend/defaults/budget-periods.v1.json") -Destination $script:budgetPeriodsFile -Force
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/services/BudgetPeriodService.ps1")

    $initial = Get-BudgetPeriodConfiguration
    Assert-Equal -Expected 4 -Actual @($initial.periods).Count -Message "The service did not read the shared configuration."

    $validPeriods = @(
        [PSCustomObject]@{ id = "P1"; startDate = "2026-04-01"; endDate = "2026-06-30" },
        [PSCustomObject]@{ id = "P2"; startDate = "2026-07-01"; endDate = "2026-09-30" },
        [PSCustomObject]@{ id = "P3"; startDate = ""; endDate = "" },
        [PSCustomObject]@{ id = "P4"; startDate = ""; endDate = "" }
    )
    $saved = Set-BudgetPeriodConfiguration -CycleLabel "2026-2027" -Periods $validPeriods
    Assert-Equal -Expected 1 -Actual $script:writeCount -Message "A valid save must perform one atomic write."
    Assert-Equal -Expected 1 -Actual $script:clearCount -Message "A valid save must invalidate the file cache."
    Assert-Equal -Expected "2026-07-01" -Actual ([string]$saved.periods[1].startDate) -Message "The saved period changed."

    $beforeInvalid = [System.IO.File]::ReadAllText($script:budgetPeriodsFile)
    $validPeriods[1].startDate = "2026-06-30"
    try {
        Set-BudgetPeriodConfiguration -CycleLabel "invalid" -Periods $validPeriods | Out-Null
        throw "An overlapping configuration was accepted."
    }
    catch [System.ArgumentException] { }
    Assert-Equal -Expected 1 -Actual $script:writeCount -Message "Invalid periods must fail before writing."
    Assert-Equal -Expected $beforeInvalid -Actual ([System.IO.File]::ReadAllText($script:budgetPeriodsFile)) -Message "An invalid save changed the shared file."

    Write-Host "Budget-period storage service tests passed."
}
finally {
    Remove-Module -Name "Saphir.BudgetPeriods" -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
