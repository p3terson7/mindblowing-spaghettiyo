$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-bug-service-{0}" -f [Guid]::NewGuid().ToString("N"))
$script:bugReportsFile = Join-Path -Path $tempRoot -ChildPath "bug-reports.json"
$script:sharedFolder = $tempRoot
$script:lockFolder = Join-Path -Path $tempRoot -ChildPath ".locks"
$script:bugReportAttachmentsFolder = Join-Path -Path $tempRoot -ChildPath "bug-report-attachments"

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ([string]$Expected -ne [string]$Actual) { throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual) } }
function Get-StatusCode { param([scriptblock]$Action) try { & $Action | Out-Null; return 0 } catch { if ($_.Exception.Data.Contains("SaphirHttpStatusCode")) { return [int]$_.Exception.Data["SaphirHttpStatusCode"] }; throw } }

try {
    New-Item -ItemType Directory -Path $tempRoot, $script:lockFolder -Force | Out-Null
    [System.IO.File]::WriteAllText($script:bugReportsFile, "[]", (New-Object System.Text.UTF8Encoding($false)))
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/FileStore.ps1")
    . (Join-Path -Path $repoRoot -ChildPath "app/backend/services/BugReportService.ps1")

    $employee = [PSCustomObject]@{ username = "employee.one"; displayName = "Employee One"; employeeCode = "000000001"; role = "employee" }
    $otherEmployee = [PSCustomObject]@{ username = "employee.two"; displayName = "Employee Two"; employeeCode = "000000002"; role = "employee" }
    $admin = [PSCustomObject]@{ username = "manager"; displayName = "Manager"; employeeCode = "000000003"; role = "admin" }
    $superAdmin = [PSCustomObject]@{ username = "owner"; displayName = "Owner"; employeeCode = "000000004"; role = "superAdmin" }
    $createInput = [PSCustomObject]@{ title = "First action fails"; description = "It fails once after login."; category = "bug" }
    $created = Add-BugReport -Input $createInput -CurrentUser $employee -NowUtc ([DateTime]"2026-09-17T14:00:00Z")

    Assert-True -Condition ([string]$created.reportId -match '^bug-[0-9a-f]{32}$') -Message "Created report id is not stable."
    Assert-Equal -Expected 1 -Actual $created.revision -Message "New report revision changed."
    Assert-Equal -Expected "new" -Actual $created.status -Message "New report status changed."
    Assert-Equal -Expected "2026-09-17T14:00:00.0000000Z" -Actual $created.createdAtUtc -Message "Injected clock was ignored."
    Assert-Equal -Expected 1 -Actual @((Get-Content -LiteralPath $script:bugReportsFile -Raw | ConvertFrom-Json)).Count -Message "Report was not atomically persisted."

    Assert-Equal -Expected 404 -Actual (Get-StatusCode { Get-BugReport -ReportId $created.reportId -CurrentUser $otherEmployee }) -Message "Another employee learned that the private report exists."
    Assert-Equal -Expected 1 -Actual @(Get-BugReports -CurrentUser $admin -Scope "all").Count -Message "Admin cannot list all reports."
    Assert-Equal -Expected 0 -Actual @(Get-BugReports -CurrentUser $otherEmployee -Scope "all").Count -Message "Employee scope exposed another reporter's report."
    $listItem = @(Get-BugReports -CurrentUser $employee -Scope "mine")[0]
    Assert-True -Condition (-not ($listItem.PSObject.Properties.Name -contains "description")) -Message "List endpoint model contains the full description."

    Assert-Equal -Expected 403 -Actual (Get-StatusCode { Update-BugReport -ReportId $created.reportId -ExpectedRevision 1 -Input ([PSCustomObject]@{ priority = "p1" }) -CurrentUser $admin }) -Message "Regular admin changed triage state."
    $reportAfterDeniedUpdate = Get-BugReport -ReportId $created.reportId -CurrentUser $employee
    Assert-Equal -Expected 1 -Actual $reportAfterDeniedUpdate.revision -Message "Denied update changed the revision."

    $edited = Update-BugReport -ReportId $created.reportId -ExpectedRevision 1 -Input ([PSCustomObject]@{ description = "More precise reproduction." }) -CurrentUser $employee -NowUtc ([DateTime]"2026-09-17T14:05:00Z")
    Assert-Equal -Expected 2 -Actual $edited.revision -Message "Reporter edit did not advance revision."
    $bytesBeforeConflict = [System.IO.File]::ReadAllBytes($script:bugReportsFile)
    Assert-Equal -Expected 409 -Actual (Get-StatusCode { Update-BugReport -ReportId $created.reportId -ExpectedRevision 1 -Input ([PSCustomObject]@{ title = "Stale" }) -CurrentUser $employee }) -Message "Stale edit did not return a conflict."
    $bytesAfterConflict = [System.IO.File]::ReadAllBytes($script:bugReportsFile)
    Assert-Equal -Expected ([Convert]::ToBase64String($bytesBeforeConflict)) -Actual ([Convert]::ToBase64String($bytesAfterConflict)) -Message "Conflict changed shared data."

    $triaged = Update-BugReport -ReportId $created.reportId -ExpectedRevision 2 -Input ([PSCustomObject]@{ status = "acknowledged"; priority = "p1"; rank = 1; assignedTo = "owner" }) -CurrentUser $superAdmin -NowUtc ([DateTime]"2026-09-17T14:10:00Z")
    Assert-Equal -Expected 3 -Actual $triaged.revision -Message "Triage did not advance revision."
    Assert-Equal -Expected "p1" -Actual $triaged.priority -Message "Priority was not saved."
    Assert-Equal -Expected 4 -Actual @($triaged.history[2].changedFields).Count -Message "Unexpected triage audit shape."
    Assert-Equal -Expected 403 -Actual (Get-StatusCode { Update-BugReport -ReportId $created.reportId -ExpectedRevision 3 -Input ([PSCustomObject]@{ title = "Too late" }) -CurrentUser $employee }) -Message "Reporter changed content after triage started."

    $stored = Get-Content -LiteralPath $script:bugReportsFile -Raw | ConvertFrom-Json
    $stored | Add-Member -NotePropertyName "futureField" -NotePropertyValue "preserve-me" -Force
    Write-JsonArrayAtomic -Path $script:bugReportsFile -Items @($stored) -Depth 16
    $futureCompatible = Update-BugReport -ReportId $created.reportId -ExpectedRevision 3 -Input ([PSCustomObject]@{ status = "resolved" }) -CurrentUser $superAdmin
    Assert-Equal -Expected "preserve-me" -Actual $futureCompatible.futureField -Message "Update removed an unknown future field."

    $attachmentReport = Add-BugReport -Input ([PSCustomObject]@{ title = "Visual issue"; description = "The card overflows."; category = "visual" }) -CurrentUser $employee
    $pngBytes = [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02)
    $attachmentResult = Add-BugReportAttachment -ReportId $attachmentReport.reportId -ExpectedRevision 1 -Bytes $pngBytes -FileName "../capture écran.png" -ContentType "image/png" -CurrentUser $employee
    Assert-Equal -Expected 2 -Actual $attachmentResult.report.revision -Message "Image upload did not advance the report revision."
    Assert-Equal -Expected "capture écran.png" -Actual $attachmentResult.attachment.fileName -Message "Image filename was not safely normalized."
    Assert-Equal -Expected "image/png" -Actual $attachmentResult.attachment.contentType -Message "Detected image type changed."
    $attachmentPath = Join-Path -Path (Join-Path -Path $script:bugReportAttachmentsFolder -ChildPath $attachmentReport.reportId) -ChildPath ("{0}.png" -f $attachmentResult.attachment.attachmentId)
    Assert-True -Condition (Test-Path -LiteralPath $attachmentPath -PathType Leaf) -Message "Image binary was not stored outside the JSON file."
    $attachmentJson = [System.IO.File]::ReadAllText($script:bugReportsFile)
    Assert-True -Condition (-not $attachmentJson.Contains([Convert]::ToBase64String($pngBytes))) -Message "Image bytes leaked into bug-reports.json."
    Assert-True -Condition (-not $attachmentJson.Contains($attachmentPath)) -Message "An absolute attachment path leaked into shared JSON."
    $download = Get-BugReportAttachment -ReportId $attachmentReport.reportId -AttachmentId $attachmentResult.attachment.attachmentId -CurrentUser $employee
    Assert-Equal -Expected ([Convert]::ToBase64String($pngBytes)) -Actual ([Convert]::ToBase64String([byte[]]$download.bytes)) -Message "Downloaded image differs from the upload."
    Assert-Equal -Expected 404 -Actual (Get-StatusCode { Get-BugReportAttachment -ReportId $attachmentReport.reportId -AttachmentId $attachmentResult.attachment.attachmentId -CurrentUser $otherEmployee }) -Message "Another employee downloaded a private image."
    Assert-Equal -Expected 403 -Actual (Get-StatusCode { Add-BugReportAttachment -ReportId $attachmentReport.reportId -ExpectedRevision 2 -Bytes $pngBytes -FileName "admin.png" -ContentType "image/png" -CurrentUser $admin }) -Message "Regular admin uploaded an image."
    Assert-Equal -Expected 409 -Actual (Get-StatusCode { Add-BugReportAttachment -ReportId $attachmentReport.reportId -ExpectedRevision 1 -Bytes $pngBytes -FileName "stale.png" -ContentType "image/png" -CurrentUser $superAdmin }) -Message "Stale image upload did not conflict."
    $invalidImageRejected = $false
    try { Add-BugReportAttachment -ReportId $attachmentReport.reportId -ExpectedRevision 2 -Bytes ([byte[]]@(1, 2, 3, 4)) -FileName "fake.png" -ContentType "image/png" -CurrentUser $employee | Out-Null }
    catch [System.ArgumentException] { $invalidImageRejected = $true }
    Assert-True -Condition $invalidImageRejected -Message "A file with a fake image type was accepted."
    $triagedAttachmentReport = Update-BugReport -ReportId $attachmentReport.reportId -ExpectedRevision 2 -Input ([PSCustomObject]@{ status = "acknowledged"; priority = "p1"; rank = 2; assignedTo = "owner" }) -CurrentUser $superAdmin
    Assert-Equal -Expected 403 -Actual (Get-StatusCode { Add-BugReportAttachment -ReportId $attachmentReport.reportId -ExpectedRevision $triagedAttachmentReport.revision -Bytes $pngBytes -FileName "late.png" -ContentType "image/png" -CurrentUser $employee }) -Message "Reporter uploaded an image after triage started."
    $rankedQueue = @(Get-BugReports -CurrentUser $superAdmin -Scope "all" -Priority "p1")
    Assert-Equal -Expected $created.reportId -Actual $rankedQueue[0].reportId -Message "Priority queue did not place rank 1 first."
    Assert-Equal -Expected $attachmentReport.reportId -Actual $rankedQueue[1].reportId -Message "Priority queue did not place rank 2 second."
    Assert-Equal -Expected "owner" -Actual $rankedQueue[1].assignedTo -Message "Queue summary omitted the triage assignee."

    $commentReport = Add-BugReport -Input ([PSCustomObject]@{ title = "Need more detail"; description = "A conversation is required."; category = "bug" }) -CurrentUser $employee
    $employeeComment = Add-BugReportComment -ReportId $commentReport.reportId -ExpectedRevision 1 -Input ([PSCustomObject]@{ body = "  It happens after signing in.  " }) -CurrentUser $employee -NowUtc ([DateTime]"2026-09-18T10:00:00Z")
    Assert-Equal -Expected 2 -Actual $employeeComment.report.revision -Message "Comment did not advance the report revision."
    Assert-Equal -Expected "It happens after signing in." -Actual $employeeComment.comment.body -Message "Stored comment was not normalized."
    Assert-Equal -Expected "Employee One" -Actual $employeeComment.comment.createdBy.displayName -Message "Comment author was not snapshotted."
    Assert-Equal -Expected 404 -Actual (Get-StatusCode { Add-BugReportComment -ReportId $commentReport.reportId -ExpectedRevision 2 -Input ([PSCustomObject]@{ body = "Private reply" }) -CurrentUser $otherEmployee }) -Message "Another employee commented on a private report."
    Assert-Equal -Expected 409 -Actual (Get-StatusCode { Add-BugReportComment -ReportId $commentReport.reportId -ExpectedRevision 1 -Input ([PSCustomObject]@{ body = "Stale reply" }) -CurrentUser $admin }) -Message "Stale comment did not return a conflict."
    $adminComment = Add-BugReportComment -ReportId $commentReport.reportId -ExpectedRevision 2 -Input ([PSCustomObject]@{ body = "Thanks, we are looking into it." }) -CurrentUser $admin
    Assert-Equal -Expected 2 -Actual @($adminComment.report.comments).Count -Message "Manager comment was not appended."
    Assert-Equal -Expected "Manager" -Actual $adminComment.comment.createdBy.displayName -Message "Manager comment has the wrong attribution."
    $closedCommentReport = Update-BugReport -ReportId $commentReport.reportId -ExpectedRevision 3 -Input ([PSCustomObject]@{ status = "closed" }) -CurrentUser $superAdmin
    Assert-Equal -Expected 409 -Actual (Get-StatusCode { Add-BugReportComment -ReportId $commentReport.reportId -ExpectedRevision $closedCommentReport.revision -Input ([PSCustomObject]@{ body = "Too late" }) -CurrentUser $employee }) -Message "Closed report accepted a comment."

    Write-Host "Bug-report storage service tests passed: privacy, authorization, attachments, locking, revisions, and forward-compatible updates are stable."
}
finally {
    Remove-Module -Name "Saphir.BugReports" -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
