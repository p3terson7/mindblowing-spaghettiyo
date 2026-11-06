$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repoRoot "app/backend/modules/Saphir.CompensationGrid.psd1") -Force

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ([string]$Expected -ne [string]$Actual) { throw "Assertion failed: $Message Expected '$Expected', got '$Actual'." }
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = ""
    try { & $Action } catch { $caught = [string]$_.Exception.Message }
    if ($caught -notlike "*$Pattern*") { throw "Assertion failed: $Message Got '$caught'." }
}

$assignments = @(ConvertTo-EmployeeCompensationAssignments -Value @(
    [PSCustomObject]@{ id = "current"; group = "as"; subGroup = "4"; level = "2"; effectiveFrom = "2026-07-01" },
    [PSCustomObject]@{ id = "past"; group = "cr"; subGroup = "4"; level = "1"; effectiveFrom = "2025-01-01"; effectiveTo = "2026-06-30" }
))

Assert-Equal 2 $assignments.Count "Both historical periods should be retained."
Assert-Equal "CR" $assignments[0].group "Assignments should be sorted and normalized."
Assert-Equal "04" $assignments[0].subGroup "Sub-group should be canonical."
Assert-Equal "02" $assignments[1].level "Level should be canonical."
Assert-Equal "past" (Resolve-EmployeeCompensationAssignment -Assignments $assignments -AsOfDate ([DateTime]"2026-06-30")).id "The historical boundary should resolve inclusively."
Assert-Equal "current" (Resolve-EmployeeCompensationAssignment -Assignments $assignments -AsOfDate ([DateTime]"2026-07-01")).id "The new period should resolve on its start date."

Assert-Throws -Pattern "cannot overlap" -Message "Overlapping employee classifications must be rejected." -Action {
    ConvertTo-EmployeeCompensationAssignments -Value @(
        [PSCustomObject]@{ id = "one"; group = "CR"; subGroup = "04"; level = "01"; effectiveFrom = "2026-01-01" },
        [PSCustomObject]@{ id = "two"; group = "AS"; subGroup = "03"; level = "01"; effectiveFrom = "2026-06-01" }
    ) | Out-Null
}

Write-Host "Employee compensation assignment tests passed."
