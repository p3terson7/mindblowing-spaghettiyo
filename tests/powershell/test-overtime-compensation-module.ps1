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

function Assert-ArgumentOutOfRange {
    param([Parameter(Mandatory = $true)][scriptblock]$Action, [Parameter(Mandatory = $true)][string]$Message)
    try {
        & $Action
    }
    catch [System.ArgumentOutOfRangeException] {
        return
    }
    throw "Assertion failed: $Message"
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$manifestPath = Join-Path -Path $repoRoot -ChildPath "app/backend/modules/Saphir.OvertimeCompensation.psd1"

$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
Assert-Equal -Expected "1.1.0" -Actual ([string]$manifest.Version) -Message "The monetary engine module version changed."
$expectedFunctions = @(
    "ConvertTo-SaphirHourlyRateCents",
    "Get-SaphirOvertimeCategory",
    "Get-SaphirOvertimeCostEstimate",
    "Get-SaphirOvertimeMonetaryContract",
    "Get-SaphirOvertimeRateCatalog",
    "Get-SaphirOvertimeRatePlan",
    "Get-SaphirOvertimeRateSegments"
) | Sort-Object
Assert-Equal -Expected ($expectedFunctions -join ",") -Actual (@($manifest.ExportedFunctions.Keys | Sort-Object) -join ",") -Message "The monetary engine exports changed."

$modulePath = Join-Path -Path $repoRoot -ChildPath "app/backend/modules/Saphir.OvertimeCompensation.psm1"
$tokens = $null
$parseErrors = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
Assert-Equal -Expected 0 -Actual @($parseErrors).Count -Message "The monetary engine has parser errors."
$forbiddenCommands = @(
    "Get-Content", "Set-Content", "Add-Content", "Out-File", "Test-Path",
    "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item", "Copy-Item",
    "Move-Item", "Invoke-WebRequest", "Invoke-RestMethod", "Get-Date",
    "Acquire-ResourceLock", "Release-ResourceLock", "Read-JsonArrayFile",
    "Write-JsonAtomic", "Write-JsonArrayAtomic"
)
$impureCommands = @($moduleAst.FindAll({
    param($node)
    return ($node -is [System.Management.Automation.Language.CommandAst] -and $forbiddenCommands -contains $node.GetCommandName())
}, $true))
Assert-Equal -Expected 0 -Actual $impureCommands.Count -Message "The monetary engine must stay pure."

Remove-Module -Name "Saphir.OvertimeCompensation" -Force -ErrorAction SilentlyContinue
Import-Module -Name $manifestPath -Force -ErrorAction Stop | Out-Null

$catalog = Get-SaphirOvertimeRateCatalog
Assert-Equal -Expected 1 -Actual $catalog.schemaVersion -Message "The rate catalog schema changed."
Assert-Equal -Expected "PA" -Actual $catalog.agreement -Message "The agreement identifier changed."
Assert-Equal -Expected "7.5" -Actual $catalog.thresholdHours -Message "The standard threshold changed."
Assert-Equal -Expected "1.5" -Actual $catalog.multipliers.timeAndHalf -Message "Time-and-a-half changed."
Assert-Equal -Expected "1.75" -Actual $catalog.multipliers.timeAndThreeQuarter -Message "Compressed-schedule multiplier changed."
Assert-Equal -Expected "2.0" -Actual ([decimal]$catalog.multipliers.doubleTime).ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture) -Message "Double-time changed."
Assert-Equal -Expected "260,261,262,263" -Actual ([string]::Join(",", @($catalog.overtimeCodes | ForEach-Object { $_.code }))) -Message "The supported GC179 codes changed."

$monetaryContract = Get-SaphirOvertimeMonetaryContract
Assert-Equal -Expected 1 -Actual $monetaryContract.schemaVersion -Message "The monetary contract schema changed."
Assert-Equal -Expected "PA-MONETARY-v1" -Actual $monetaryContract.calculationVersion -Message "The monetary calculation version changed."
Assert-Equal -Expected "CAD" -Actual $monetaryContract.currency -Message "The monetary currency changed."
Assert-Equal -Expected "salary-only" -Actual $monetaryContract.costBasis -Message "The estimate cost basis changed."
Assert-Equal -Expected $false -Actual ([bool]$monetaryContract.includesEmployerCosts) -Message "Employer costs must not be implied by the salary estimate."
Assert-Equal -Expected "52.176" -Actual $monetaryContract.weeksPerYear -Message "The PA annual-to-weekly divisor changed."
Assert-Equal -Expected "37.5" -Actual $monetaryContract.standardHoursPerWeek -Message "The PA weekly hours changed."
Assert-Equal -Expected "1956.6" -Actual $monetaryContract.annualHoursDivisor -Message "The PA annual-hours divisor changed."
Assert-Equal -Expected "away-from-zero" -Actual $monetaryContract.rounding.midpoint -Message "The monetary midpoint rule changed."
Assert-Equal -Expected "entry-total" -Actual $monetaryContract.rounding.scope -Message "Entry-level rounding changed."

Assert-Equal -Expected "regular" -Actual (Get-SaphirOvertimeCategory -OvertimeCode "260") -Message "Code 260 must use the regular category."
Assert-Equal -Expected "first-day-rest" -Actual (Get-SaphirOvertimeCategory -OvertimeCode "261") -Message "Code 261 must use the first-rest category."
Assert-Equal -Expected "subsequent-day-rest" -Actual (Get-SaphirOvertimeCategory -OvertimeCode "262") -Message "Code 262 must use the subsequent-rest category."
Assert-Equal -Expected "holiday" -Actual (Get-SaphirOvertimeCategory -OvertimeCode "263") -Message "Code 263 must use the holiday category."

$regularPlan = Get-SaphirOvertimeRatePlan -OvertimeCode "260" -WorkSchedule "regular"
Assert-Equal -Expected "1.5" -Actual $regularPlan.baseMultiplier -Message "Regular workday base rate is wrong."
Assert-Equal -Expected "7.5" -Actual $regularPlan.thresholdHours -Message "Regular workday threshold is wrong."
Assert-Equal -Expected "2.0" -Actual ([decimal]$regularPlan.excessMultiplier).ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture) -Message "Regular workday excess rate is wrong."

$compressedPlan = Get-SaphirOvertimeRatePlan -OvertimeCode "262" -WorkSchedule "compressed"
Assert-Equal -Expected "1.75" -Actual $compressedPlan.baseMultiplier -Message "Compressed rest-day rate is wrong."
Assert-True -Condition ($null -eq $compressedPlan.thresholdHours) -Message "Compressed rest-day overtime must not use the regular 7.5-hour threshold."

$secondRestPlan = Get-SaphirOvertimeRatePlan -OvertimeCode "262" -WorkSchedule "regular"
Assert-Equal -Expected "2.0" -Actual ([decimal]$secondRestPlan.baseMultiplier).ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture) -Message "Second-rest-day rate is wrong."

$compressedHolidayPlan = Get-SaphirOvertimeRatePlan -OvertimeCode "263" -WorkSchedule "compressed"
Assert-Equal -Expected "1.5" -Actual $compressedHolidayPlan.baseMultiplier -Message "Compressed holiday fallback rate is wrong."

$adjacentHolidayPlan = Get-SaphirOvertimeRatePlan -OvertimeCode "263" -WorkSchedule "regular" -HolidayAdjacentToSecondRest $true
Assert-Equal -Expected "2.0" -Actual ([decimal]$adjacentHolidayPlan.baseMultiplier).ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture) -Message "Adjacent-holiday rate is wrong."

$segments = @(Get-SaphirOvertimeRateSegments -OvertimeCode "261" -WorkSchedule "regular" -Hours ([decimal]3) -PreviouslyCreditedHours ([decimal]6))
Assert-Equal -Expected 2 -Actual $segments.Count -Message "A row crossing the daily threshold must split in two."
Assert-Equal -Expected "1.5" -Actual $segments[0].multiplier -Message "The first split multiplier is wrong."
Assert-Equal -Expected "1.5" -Actual $segments[0].hours -Message "The first split duration is wrong."
Assert-Equal -Expected "2.0" -Actual ([decimal]$segments[1].multiplier).ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture) -Message "The second split multiplier is wrong."
Assert-Equal -Expected "1.5" -Actual $segments[1].hours -Message "The second split duration is wrong."

$zeroSegments = @(Get-SaphirOvertimeRateSegments -OvertimeCode "260" -WorkSchedule "regular" -Hours 0)
Assert-Equal -Expected 0 -Actual $zeroSegments.Count -Message "Zero hours must not create a compensation segment."

$hourlyRateCents = ConvertTo-SaphirHourlyRateCents -AnnualSalaryCents 8367500
Assert-Equal -Expected "4276.551160" -Actual ([decimal]::Round($hourlyRateCents, 6, [System.MidpointRounding]::AwayFromZero).ToString("0.000000", [System.Globalization.CultureInfo]::InvariantCulture)) -Message "Annual salary conversion changed."

$cashEstimate = Get-SaphirOvertimeCostEstimate -AnnualSalaryCents 8367500 -OvertimeCode "260" -WorkSchedule "regular" -CreditedMinutes 120
Assert-Equal -Expected "estimated" -Actual $cashEstimate.calculationStatus -Message "A valid calculation must remain explicitly estimated."
Assert-Equal -Expected $true -Actual ([bool]$cashEstimate.estimateOnly) -Message "The estimate-only guard changed."
Assert-Equal -Expected "salary-only" -Actual $cashEstimate.costBasis -Message "The estimate did not expose its cost basis."
Assert-Equal -Expected 12830 -Actual $cashEstimate.totalAmountCents -Message "Two regular overtime hours at 1.5x are wrong."
Assert-Equal -Expected 12830 -Actual $cashEstimate.cashAmountCents -Message "Cash overtime was not classified as cash value."
Assert-Equal -Expected 0 -Actual $cashEstimate.compensatoryLeaveValueCents -Message "Cash overtime leaked into leave liability."
Assert-Equal -Expected 120 -Actual $cashEstimate.segments[0].creditedMinutes -Message "The cost segment lost credited minutes."

$leaveEstimate = Get-SaphirOvertimeCostEstimate -AnnualSalaryCents 8367500 -OvertimeCode "260" -WorkSchedule "compressed" -CreditedMinutes 120 -PaymentOption "leave"
Assert-Equal -Expected 14968 -Actual $leaveEstimate.totalAmountCents -Message "Compressed overtime at 1.75x is wrong."
Assert-Equal -Expected 0 -Actual $leaveEstimate.cashAmountCents -Message "Compensatory leave was counted as immediate cash."
Assert-Equal -Expected 14968 -Actual $leaveEstimate.compensatoryLeaveValueCents -Message "Compensatory leave economic value is wrong."

$splitEstimate = Get-SaphirOvertimeCostEstimate -AnnualSalaryCents 8367500 -OvertimeCode "261" -WorkSchedule "regular" -CreditedMinutes 180 -PreviouslyCreditedMinutes 360
Assert-Equal -Expected 2 -Actual @($splitEstimate.segments).Count -Message "A monetary entry crossing 7.5 hours must split."
Assert-Equal -Expected 90 -Actual $splitEstimate.segments[0].creditedMinutes -Message "The 1.5x split duration is wrong."
Assert-Equal -Expected 90 -Actual $splitEstimate.segments[1].creditedMinutes -Message "The 2x split duration is wrong."
Assert-Equal -Expected 22452 -Actual $splitEstimate.totalAmountCents -Message "The split monetary total is wrong."
Assert-Equal -Expected $splitEstimate.totalAmountCents -Actual (($splitEstimate.segments | Measure-Object -Property amountCents -Sum).Sum) -Message "Rounded segments must reconcile to the rounded entry total."

$unconfirmed = Get-SaphirOvertimeCostEstimate -AnnualSalaryCents 8367500 -OvertimeCode "260" -WorkSchedule "unconfirmed" -CreditedMinutes 60
Assert-Equal -Expected "unavailable" -Actual $unconfirmed.calculationStatus -Message "An unconfirmed schedule must not invent an amount."
Assert-Equal -Expected "work-schedule-unconfirmed" -Actual $unconfirmed.unavailableReason -Message "The unavailable reason changed."
Assert-True -Condition ($null -eq $unconfirmed.totalAmountCents) -Message "An unconfirmed schedule exposed a monetary total."

Assert-ArgumentOutOfRange -Action { ConvertTo-SaphirHourlyRateCents -AnnualSalaryCents 0 | Out-Null } -Message "A zero annual salary was accepted."
Assert-ArgumentOutOfRange -Action { Get-SaphirOvertimeCostEstimate -AnnualSalaryCents 8367500 -OvertimeCode "260" -WorkSchedule "regular" -CreditedMinutes 10 | Out-Null } -Message "A non-quarter-hour credit was accepted."
Assert-ArgumentOutOfRange -Action { Get-SaphirOvertimeCostEstimate -AnnualSalaryCents 8367500 -OvertimeCode "260" -WorkSchedule "regular" -CreditedMinutes 15 -PreviouslyCreditedMinutes -15 | Out-Null } -Message "Negative previous credit was accepted."

Write-Host "Overtime compensation module tests passed."
