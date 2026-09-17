$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$backendRoot = Join-Path -Path $repoRoot -ChildPath "app/backend"
$manifestPath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.BudgetPeriods.psd1"
$modulePath = Join-Path -Path $backendRoot -ChildPath "modules/Saphir.BudgetPeriods.psm1"
$templatePath = Join-Path -Path $backendRoot -ChildPath "defaults/budget-periods.v1.json"

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

function Assert-ArgumentError {
    param([Parameter(Mandatory = $true)][scriptblock]$Action, [Parameter(Mandatory = $true)][string]$Message)
    try {
        & $Action
    }
    catch [System.ArgumentException] {
        return
    }
    throw $Message
}

foreach ($path in @($manifestPath, $modulePath, $templatePath)) {
    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message ("Missing budget-period file: {0}" -f $path)
}

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
$expectedFunctions = @(
    "ConvertTo-SaphirBudgetPeriodConfiguration",
    "Get-SaphirBudgetPeriodIds",
    "Get-SaphirConfiguredBudgetPeriods"
) | Sort-Object
Assert-Equal -Expected ($expectedFunctions -join ",") -Actual (@($manifest.FunctionsToExport | Sort-Object) -join ",") -Message "The budget-period module exports changed."
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "The module must remain compatible with Windows PowerShell 5.1."

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Equal -Expected 0 -Actual @($parseErrors).Count -Message "The budget-period module has parser errors."

Import-Module -Name $manifestPath -Force -ErrorAction Stop
Assert-Equal -Expected "P1,P2,P3,P4" -Actual (@(Get-SaphirBudgetPeriodIds) -join ",") -Message "The period identity contract changed."

$template = [System.IO.File]::ReadAllText($templatePath) | ConvertFrom-Json -ErrorAction Stop
$normalizedTemplate = ConvertTo-SaphirBudgetPeriodConfiguration -Value $template
Assert-Equal -Expected 4 -Actual @($normalizedTemplate.periods).Count -Message "The template must contain four periods."
Assert-Equal -Expected 0 -Actual @(Get-SaphirConfiguredBudgetPeriods -Configuration $template).Count -Message "The shipped template must not invent department budget dates."

$valid = [PSCustomObject]@{
    schemaVersion = 1
    cycleLabel = "2026-2027"
    periods = @(
        [PSCustomObject]@{ id = "p1"; startDate = "2026-04-01"; endDate = "2026-06-30" },
        [PSCustomObject]@{ id = "P2"; startDate = "2026-07-01"; endDate = "2026-09-30" },
        [PSCustomObject]@{ id = "P3"; startDate = ""; endDate = "" },
        [PSCustomObject]@{ id = "P4"; startDate = ""; endDate = "" }
    )
}
$normalized = ConvertTo-SaphirBudgetPeriodConfiguration -Value $valid
Assert-Equal -Expected "P1" -Actual ([string]$normalized.periods[0].id) -Message "Period IDs must normalize to uppercase."
Assert-Equal -Expected $true -Actual ([bool]$normalized.periods[0].configured) -Message "A complete period must be configured."
Assert-Equal -Expected 2 -Actual @(Get-SaphirConfiguredBudgetPeriods -Configuration $valid).Count -Message "Configured-period filtering changed."

$partial = $valid | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$partial.periods[1].endDate = ""
Assert-ArgumentError -Action { ConvertTo-SaphirBudgetPeriodConfiguration -Value $partial | Out-Null } -Message "A one-sided period range was accepted."

$overlap = $valid | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$overlap.periods[1].startDate = "2026-06-30"
Assert-ArgumentError -Action { ConvertTo-SaphirBudgetPeriodConfiguration -Value $overlap | Out-Null } -Message "Overlapping budget periods were accepted."

$invalidDate = $valid | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$invalidDate.periods[0].startDate = "2026-02-29"
Assert-ArgumentError -Action { ConvertTo-SaphirBudgetPeriodConfiguration -Value $invalidDate | Out-Null } -Message "An invalid calendar date was accepted."

Remove-Module -Name "Saphir.BudgetPeriods" -Force -ErrorAction SilentlyContinue
Write-Host "Budget-period module tests passed."
