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
$readModelPath = Join-Path -Path $repoRoot -ChildPath "app/backend/services/ReadModelService.ps1"
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($readModelPath, [ref]$tokens, [ref]$errors)
Assert-Equal -Expected 0 -Actual @($errors).Count -Message "ReadModelService has parser errors."

$functionAst = $ast.Find({
    param($node)
    return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "New-HistoryEntryReadModel")
}, $true)
Assert-True -Condition ($null -ne $functionAst) -Message "The history employee projection is missing."
Invoke-Expression $functionAst.Extent.Text

$employeeNames = [PSCustomObject]@{ "000123456" = "Sophie Tremblay" }
$legacyCodeEntry = [PSCustomObject]@{
    action = "Update"
    employee = "000123456"
    message = "Updated an entry on September 2, 2026."
}
$projection = New-HistoryEntryReadModel -Entry $legacyCodeEntry -EmployeeNameMap $employeeNames
Assert-Equal -Expected "Sophie Tremblay" -Actual $projection.targetEmployeeName -Message "A legacy HRMIS history subject was not enriched with its employee name."
Assert-Equal -Expected "000123456" -Actual $projection.targetEmployeeCode -Message "The HRMIS identifier was not retained as secondary information."
Assert-True -Condition (-not ($legacyCodeEntry.PSObject.Properties.Name -contains "targetEmployeeName")) -Message "The read projection mutated its source entry."

$legacyNameEntry = [PSCustomObject]@{
    action = "Delete"
    targetEmployee = "Sophie Tremblay"
    message = "Deleted an entry on September 2, 2026."
}
$nameProjection = New-HistoryEntryReadModel -Entry $legacyNameEntry -EmployeeNameMap $employeeNames
Assert-Equal -Expected "Sophie Tremblay" -Actual $nameProjection.targetEmployeeName -Message "An existing employee name changed."
Assert-Equal -Expected "000123456" -Actual $nameProjection.targetEmployeeCode -Message "A named history subject did not resolve its HRMIS identifier."

Write-Host "History employee read-model tests passed."
