$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    if ([string]$Expected -cne [string]$Actual) {
        throw "Assertion failed: $Message Expected '$Expected', got '$Actual'."
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$manifestPath = Join-Path -Path $repoRoot -ChildPath "app/backend/modules/Saphir.BusinessRules.psd1"

Test-ModuleManifest -Path $manifestPath -ErrorAction Stop | Out-Null
Remove-Module -Name "Saphir.BusinessRules" -Force -ErrorAction SilentlyContinue
Import-Module -Name $manifestPath -Force -ErrorAction Stop | Out-Null

$contract = Get-SaphirBusinessRuleContract
Assert-Equal -Expected 1 -Actual $contract.contractVersion -Message "The contract version changed."
Assert-Equal -Expected "overtime,diverse" -Actual ([string]::Join(",", @($contract.entryTypes))) -Message "Entry types changed."
Assert-Equal -Expected "regular,compressed,unconfirmed" -Actual ([string]::Join(",", @($contract.workSchedules))) -Message "Work schedules changed."
Assert-Equal -Expected "P1,P2,P3,P4" -Actual ([string]::Join(",", @($contract.budgetPeriodIds))) -Message "Budget period identifiers changed."

Assert-Equal -Expected "overtime" -Actual (ConvertTo-SaphirEntryType -Value $null) -Message "Legacy entries must default to overtime."
Assert-Equal -Expected "diverse" -Actual (ConvertTo-SaphirEntryType -Value " DIVERSE ") -Message "Diverse normalization failed."
Assert-Equal -Expected "overtime" -Actual (ConvertTo-SaphirEntryType -Value "unexpected") -Message "Invalid entry types must fail safely."

Assert-Equal -Expected "unconfirmed" -Actual (ConvertTo-SaphirWorkSchedule -Value $null) -Message "Legacy schedules must remain unconfirmed."
Assert-Equal -Expected "regular" -Actual (ConvertTo-SaphirWorkSchedule -Value "standard") -Message "The standard alias must normalize to regular."
Assert-Equal -Expected "compressed" -Actual (ConvertTo-SaphirWorkSchedule -Value " COMPRESSED ") -Message "Compressed normalization failed."

Assert-True -Condition (Test-SaphirClassificationGroup -Value "CR") -Message "Alphabetic groups must be valid."
Assert-True -Condition (-not (Test-SaphirClassificationGroup -Value "CR-04")) -Message "Group digits and punctuation must be rejected by the target contract."
Assert-True -Condition (Test-SaphirClassificationOrdinal -Value "04") -Message "Two-digit subgroup values must be valid."
Assert-True -Condition (-not (Test-SaphirClassificationOrdinal -Value "4")) -Message "Unpadded subgroup or level values must be invalid."
Assert-True -Condition (-not (Test-SaphirClassificationOrdinal -Value "004")) -Message "Three-digit subgroup or level values must be invalid."

Write-Host "Business-rule contract tests passed."
