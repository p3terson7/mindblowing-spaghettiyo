$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$manifestPath = Join-Path -Path $repoRoot -ChildPath "app/backend/modules/Saphir.BugReports.psd1"
$modulePath = Join-Path -Path $repoRoot -ChildPath "app/backend/modules/Saphir.BugReports.psm1"

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ([string]$Expected -ne [string]$Actual) { throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual) } }
function Assert-ArgumentError { param([scriptblock]$Action, [string]$Message) try { & $Action; throw $Message } catch [System.ArgumentException] { } }

$expectedExports = @(
    "ConvertTo-SaphirBugReportCreateInput",
    "ConvertTo-SaphirBugReportCommentInput",
    "ConvertTo-SaphirBugReportPatchInput",
    "Test-SaphirBugReportVisible",
    "Test-SaphirBugReportReporterEditAllowed",
    "Test-SaphirBugReportAdministrativeUser",
    "New-SaphirBugReportSummary"
)

Assert-True -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Message "Bug-report manifest is missing."
$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Assert-Equal -Expected "5.1" -Actual ([string]$manifest.PowerShellVersion) -Message "Bug-report module must support Windows PowerShell 5.1."
Assert-Equal -Expected (($expectedExports | Sort-Object) -join "|") -Actual ((@($manifest.FunctionsToExport) | Sort-Object) -join "|") -Message "Bug-report manifest exports changed."

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
Assert-Equal -Expected 0 -Actual @($parseErrors).Count -Message "Bug-report module has parser errors."
$forbiddenCommands = @("Get-Content", "Set-Content", "Add-Content", "Out-File", "Test-Path", "Get-Item", "Get-ChildItem", "New-Item", "Remove-Item", "Copy-Item", "Move-Item", "Get-Date", "Read-JsonArrayFile", "Write-JsonAtomic", "Write-JsonArrayAtomic", "Acquire-ResourceLock")
$sideEffects = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $forbiddenCommands -contains [string]$node.GetCommandName() }, $true))
Assert-Equal -Expected 0 -Actual $sideEffects.Count -Message "Pure bug-report rules perform side effects."

Remove-Module -Name "Saphir.BugReports" -Force -ErrorAction SilentlyContinue
$module = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
Assert-Equal -Expected (($expectedExports | Sort-Object) -join "|") -Actual ((@($module.ExportedCommands.Keys) | Sort-Object) -join "|") -Message "Runtime module exports changed."

$input = [PSCustomObject]@{
    title = "  First action fails  "
    description = "  Reproducible after login.  "
    category = "BUG"
    technicalContext = [PSCustomObject]@{ page = " /review "; appVersion = "1.2.3" }
}
$validated = ConvertTo-SaphirBugReportCreateInput -Value $input
Assert-Equal -Expected "First action fails" -Actual $validated.title -Message "Title was not normalized."
Assert-Equal -Expected "bug" -Actual $validated.category -Message "Category was not canonicalized."
Assert-Equal -Expected "/review" -Actual $validated.technicalContext.page -Message "Technical context was not normalized."
Assert-ArgumentError -Action { ConvertTo-SaphirBugReportCreateInput -Value ([PSCustomObject]@{ title = ""; description = "x"; category = "bug" }) | Out-Null } -Message "An empty title was accepted."
Assert-ArgumentError -Action { ConvertTo-SaphirBugReportCreateInput -Value ([PSCustomObject]@{ title = "x"; description = "y"; category = "unknown" }) | Out-Null } -Message "An unknown category was accepted."

$comment = ConvertTo-SaphirBugReportCommentInput -Value ([PSCustomObject]@{ body = "  I can reproduce this.  " })
Assert-Equal -Expected "I can reproduce this." -Actual $comment.body -Message "Comment body was not normalized."
Assert-ArgumentError -Action { ConvertTo-SaphirBugReportCommentInput -Value ([PSCustomObject]@{ body = "   " }) | Out-Null } -Message "An empty comment was accepted."
Assert-ArgumentError -Action { ConvertTo-SaphirBugReportCommentInput -Value ([PSCustomObject]@{ body = ("x" * 3001) }) | Out-Null } -Message "An oversized comment was accepted."

$patch = ConvertTo-SaphirBugReportPatchInput -Value ([PSCustomObject]@{ title = "Updated"; priority = "P1"; rank = 2 })
Assert-Equal -Expected "title" -Actual (@($patch.contentFieldNames) -join "|") -Message "Content fields were classified incorrectly."
Assert-Equal -Expected "priority|rank" -Actual (@($patch.administrativeFieldNames) -join "|") -Message "Administrative fields were classified incorrectly."

$owner = [PSCustomObject]@{ username = "employee.one"; role = "employee" }
$other = [PSCustomObject]@{ username = "employee.two"; role = "employee" }
$admin = [PSCustomObject]@{ username = "manager"; role = "admin" }
$superAdmin = [PSCustomObject]@{ username = "owner"; role = "superAdmin" }
$report = [PSCustomObject]@{
    reportId = "bug-0123456789abcdef0123456789abcdef"; revision = 1; title = "Title"; description = ("a" * 300)
    category = "bug"; status = "new"; priority = "unranked"; rank = 0
    createdBy = [PSCustomObject]@{ username = "employee.one"; displayName = "Employee One" }
    createdAtUtc = "2026-09-17T10:00:00.0000000Z"; updatedAtUtc = "2026-09-17T10:00:00.0000000Z"
    attachments = @(); comments = @()
}
Assert-True -Condition (Test-SaphirBugReportVisible -Report $report -User $owner) -Message "Reporter cannot see their report."
Assert-True -Condition (-not (Test-SaphirBugReportVisible -Report $report -User $other)) -Message "Another employee can see a private report."
Assert-True -Condition (Test-SaphirBugReportVisible -Report $report -User $admin) -Message "Admin cannot see reports."
Assert-True -Condition (Test-SaphirBugReportAdministrativeUser -User $superAdmin) -Message "Super admin cannot triage reports."
Assert-True -Condition (-not (Test-SaphirBugReportAdministrativeUser -User $admin)) -Message "Regular admin can triage reports."
Assert-True -Condition (Test-SaphirBugReportReporterEditAllowed -Report $report -User $owner) -Message "Reporter cannot edit a new report."
$report.status = "acknowledged"
Assert-True -Condition (-not (Test-SaphirBugReportReporterEditAllowed -Report $report -User $owner)) -Message "Reporter can edit a report after triage started."

$summary = New-SaphirBugReportSummary -Report $report
Assert-True -Condition (-not ($summary.PSObject.Properties.Name -contains "assignedTo")) -Message "Summary still exposes the removed assignee concept."
Assert-True -Condition ($summary.descriptionPreview.Length -le 240) -Message "List preview is too long."
Assert-True -Condition (-not ($summary.PSObject.Properties.Name -contains "description")) -Message "List summary exposes the full description."

Remove-Module -Name "Saphir.BugReports" -Force -ErrorAction SilentlyContinue
Write-Host "Bug-report module tests passed: pure validation, permissions, and list projection are stable."
