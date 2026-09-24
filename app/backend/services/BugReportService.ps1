$bugReportModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.BugReports.psd1"
Import-Module -Name $bugReportModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name bugReportModuleManifest -ErrorAction SilentlyContinue

function New-BugReportServiceException {
    param(
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data["SaphirHttpStatusCode"] = $StatusCode
    return $exception
}

function Set-BugReportProperty {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Value
    )

    if ($Record.PSObject.Properties.Name -contains $Name) {
        $Record.$Name = $Value
    }
    else {
        $Record | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function New-BugReportActorSnapshot {
    param([Parameter(Mandatory = $true)]$User)

    $username = ([string]$User.username).Trim()
    $displayName = ([string]$User.displayName).Trim()
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $username }
    return [PSCustomObject][ordered]@{
        username     = $username
        displayName  = $displayName
        employeeCode = ([string]$User.employeeCode).Trim()
        role          = ([string]$User.role).Trim()
    }
}

$script:BugReportAttachmentMaximumBytes = 8388608
$script:BugReportAttachmentMaximumCount = 5
$script:BugReportCommentMaximumCount = 250

function Get-BugReportAttachmentFormat {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if ($Bytes.Length -ge 8 -and
        $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47 -and
        $Bytes[4] -eq 0x0D -and $Bytes[5] -eq 0x0A -and $Bytes[6] -eq 0x1A -and $Bytes[7] -eq 0x0A) {
        return [PSCustomObject]@{ contentType = 'image/png'; extension = 'png' }
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF) {
        return [PSCustomObject]@{ contentType = 'image/jpeg'; extension = 'jpg' }
    }
    if ($Bytes.Length -ge 6) {
        $signature = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 6)
        if ($signature -eq 'GIF87a' -or $signature -eq 'GIF89a') {
            return [PSCustomObject]@{ contentType = 'image/gif'; extension = 'gif' }
        }
    }
    if ($Bytes.Length -ge 12 -and
        [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -eq 'RIFF' -and
        [System.Text.Encoding]::ASCII.GetString($Bytes, 8, 4) -eq 'WEBP') {
        return [PSCustomObject]@{ contentType = 'image/webp'; extension = 'webp' }
    }
    throw [System.ArgumentException]::new('Only PNG, JPEG, GIF, and WebP images are accepted.')
}

function ConvertTo-BugReportAttachmentFileName {
    param([AllowNull()][string]$FileName)

    $name = [System.IO.Path]::GetFileName(([string]$FileName).Trim())
    $name = ($name -replace '[\x00-\x1F\x7F]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'capture' }
    if ($name.Length -gt 180) { $name = $name.Substring(0, 180) }
    return $name
}

function Get-BugReportAttachmentPath {
    param(
        [Parameter(Mandatory = $true)][string]$ReportId,
        [Parameter(Mandatory = $true)][string]$AttachmentId,
        [Parameter(Mandatory = $true)][string]$Extension
    )

    if ($ReportId -notmatch '^bug-[0-9a-fA-F]{32}$' -or
        $AttachmentId -notmatch '^attachment-[0-9a-fA-F]{32}$' -or
        $Extension -notin @('png', 'jpg', 'gif', 'webp')) {
        throw [System.IO.InvalidDataException]::new('Invalid bug-report attachment metadata.')
    }
    $reportFolder = Join-Path -Path $bugReportAttachmentsFolder -ChildPath $ReportId.ToLowerInvariant()
    return (Join-Path -Path $reportFolder -ChildPath ("{0}.{1}" -f $AttachmentId.ToLowerInvariant(), $Extension))
}

function Write-BugReportAttachmentFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $parent = Split-Path -Path $Path -Parent
    try {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    catch {
        throw (New-SharedDataUnavailableException -Operation 'prepare attachment folder' -Path $Path -InnerException $_.Exception)
    }
    $temporaryPath = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
    try {
        $temporaryWritten = $false
        $lastWriteError = $null
        for ($attempt = 1; $attempt -le $script:SharedDataReadRetryCount; $attempt++) {
            try {
                [System.IO.File]::WriteAllBytes($temporaryPath, $Bytes)
                $temporaryWritten = $true
                break
            }
            catch {
                $lastWriteError = $_
                if ($attempt -lt $script:SharedDataReadRetryCount) { Start-SharedDataRetryDelay -Attempt $attempt }
            }
        }
        if (-not $temporaryWritten) {
            throw (New-SharedDataUnavailableException -Operation 'write temporary attachment' -Path $Path -InnerException $lastWriteError.Exception)
        }

        $committed = $false
        $lastCommitError = $null
        for ($attempt = 1; $attempt -le $script:SharedDataReadRetryCount; $attempt++) {
            try {
                Move-Item -LiteralPath $temporaryPath -Destination $Path -Force -ErrorAction Stop
                $committed = $true
                break
            }
            catch {
                $lastCommitError = $_
                # SMB can report an error after the server committed the move.
                # Verify an ambiguous outcome before attempting another write.
                try {
                    $destinationBytes = [System.IO.File]::ReadAllBytes($Path)
                    if ([Convert]::ToBase64String($destinationBytes) -ceq [Convert]::ToBase64String($Bytes)) {
                        $committed = $true
                        break
                    }
                }
                catch { }
                if ($attempt -lt $script:SharedDataReadRetryCount) { Start-SharedDataRetryDelay -Attempt $attempt }
            }
        }
        if (-not $committed) {
            throw (New-SharedDataUnavailableException -Operation 'commit attachment' -Path $Path -InnerException $lastCommitError.Exception)
        }
        Clear-CachedFileContent -Path $Path
    }
    catch {
        throw (New-SharedDataUnavailableException -Operation 'write attachment' -Path $Path -InnerException $_.Exception)
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Clear-BugReportRuntimeCache {
    if (-not [string]::IsNullOrWhiteSpace([string]$bugReportsFile)) {
        Clear-CachedFileContent -Path $bugReportsFile
    }
}

function Read-BugReportCollection {
    if ([string]::IsNullOrWhiteSpace([string]$bugReportsFile)) {
        throw "The shared bug-report path is not configured."
    }

    $reports = @(Read-JsonArrayFile -Path $bugReportsFile)
    $seen = @{}
    foreach ($report in $reports) {
        $reportId = ([string]$report.reportId).Trim()
        $revision = 0
        $schemaVersion = 0
        if ($null -eq $report -or
            -not [int]::TryParse([string]$report.schemaVersion, [ref]$schemaVersion) -or
            $schemaVersion -ne 1 -or
            $reportId -notmatch '^bug-[0-9a-fA-F]{32}$' -or
            -not [int]::TryParse([string]$report.revision, [ref]$revision) -or
            $revision -lt 1) {
            throw [System.IO.InvalidDataException]::new("The shared bug-report collection contains an invalid record.")
        }
        try {
            Saphir.BugReports\ConvertTo-SaphirBugReportCreateInput -Value $report | Out-Null
            Saphir.BugReports\ConvertTo-SaphirBugReportPatchInput -Value ([PSCustomObject]@{
                status   = $report.status
                priority = $report.priority
                rank     = $report.rank
            }) | Out-Null
        }
        catch [System.ArgumentException] {
            throw [System.IO.InvalidDataException]::new("The shared bug-report collection contains an invalid record.", $_.Exception)
        }
        if ($null -eq $report.createdBy -or
            [string]::IsNullOrWhiteSpace(([string]$report.createdBy.username).Trim()) -or
            -not ($report.attachments -is [System.Collections.IEnumerable]) -or $report.attachments -is [string] -or
            -not ($report.comments -is [System.Collections.IEnumerable]) -or $report.comments -is [string] -or
            -not ($report.history -is [System.Collections.IEnumerable]) -or $report.history -is [string]) {
            throw [System.IO.InvalidDataException]::new("The shared bug-report collection contains an invalid record.")
        }
        foreach ($attachment in @($report.attachments)) {
            $attachmentId = ([string]$attachment.attachmentId).Trim()
            $attachmentContentType = ([string]$attachment.contentType).Trim().ToLowerInvariant()
            $attachmentSize = 0L
            if ($attachmentId -notmatch '^attachment-[0-9a-fA-F]{32}$' -or
                [string]::IsNullOrWhiteSpace(([string]$attachment.fileName).Trim()) -or
                $attachmentContentType -notin @('image/png', 'image/jpeg', 'image/gif', 'image/webp') -or
                -not [Int64]::TryParse([string]$attachment.byteLength, [ref]$attachmentSize) -or
                $attachmentSize -lt 1 -or $attachmentSize -gt $script:BugReportAttachmentMaximumBytes) {
                throw [System.IO.InvalidDataException]::new("The shared bug-report collection contains invalid attachment metadata.")
            }
        }
        foreach ($comment in @($report.comments)) {
            if (([string]$comment.commentId).Trim() -notmatch '^comment-[0-9a-fA-F]{32}$' -or
                [string]::IsNullOrWhiteSpace(([string]$comment.body).Trim()) -or
                ([string]$comment.body).Length -gt 3000 -or
                $null -eq $comment.createdBy -or
                [string]::IsNullOrWhiteSpace(([string]$comment.createdBy.username).Trim()) -or
                [string]::IsNullOrWhiteSpace(([string]$comment.createdAtUtc).Trim())) {
                throw [System.IO.InvalidDataException]::new("The shared bug-report collection contains invalid comment metadata.")
            }
        }
        $key = $reportId.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw [System.IO.InvalidDataException]::new("The shared bug-report collection contains duplicate identifiers.")
        }
        $seen[$key] = $true
    }
    return $reports
}

function Test-BugReportMatchesFilter {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [AllowNull()][string]$Status,
        [AllowNull()][string]$Priority,
        [AllowNull()][string]$Category
    )

    if (-not [string]::IsNullOrWhiteSpace($Status) -and -not ([string]$Report.status).Equals($Status, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Priority) -and -not ([string]$Report.priority).Equals($Priority, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Category) -and -not ([string]$Report.category).Equals($Category, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $true
}

function Get-BugReports {
    param(
        [Parameter(Mandatory = $true)]$CurrentUser,
        [AllowNull()][string]$Scope,
        [AllowNull()][string]$Status,
        [AllowNull()][string]$Priority,
        [AllowNull()][string]$Category
    )

    $username = ([string]$CurrentUser.username).Trim()
    $normalizedScope = ([string]$Scope).Trim().ToLowerInvariant()
    if ($normalizedScope -notin @('', 'mine', 'all')) {
        throw [System.ArgumentException]::new("Scope must be mine or all.")
    }
    $role = ([string]$CurrentUser.role).Trim()
    $manager = $role.Equals('admin', [System.StringComparison]::OrdinalIgnoreCase) -or
        $role.Equals('superAdmin', [System.StringComparison]::OrdinalIgnoreCase)
    $mineOnly = -not $manager -or $normalizedScope -eq 'mine'

    $priorityOrder = @{ p1 = 0; p2 = 1; p3 = 2; p4 = 3; unranked = 4 }
    $visible = @(Read-BugReportCollection | Where-Object {
        if (-not (Saphir.BugReports\Test-SaphirBugReportVisible -Report $_ -User $CurrentUser)) { return $false }
        if ($mineOnly -and -not ([string]$_.createdBy.username).Equals($username, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        return (Test-BugReportMatchesFilter -Report $_ -Status $Status -Priority $Priority -Category $Category)
    } | Sort-Object `
        @{ Expression = { $key = ([string]$_.priority).ToLowerInvariant(); if ($priorityOrder.ContainsKey($key)) { $priorityOrder[$key] } else { 5 } } }, `
        @{ Expression = { [Int64]$_.rank } }, `
        @{ Expression = { [string]$_.updatedAtUtc }; Descending = $true })

    return @($visible | ForEach-Object { Saphir.BugReports\New-SaphirBugReportSummary -Report $_ })
}

function Get-BugReport {
    param(
        [Parameter(Mandatory = $true)][string]$ReportId,
        [Parameter(Mandatory = $true)]$CurrentUser
    )

    $normalizedId = $ReportId.Trim()
    $report = Read-BugReportCollection | Where-Object { ([string]$_.reportId).Equals($normalizedId, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if ($null -eq $report) {
        throw (New-BugReportServiceException -StatusCode 404 -Message "Bug report not found.")
    }
    if (-not (Saphir.BugReports\Test-SaphirBugReportVisible -Report $report -User $CurrentUser)) {
        # Do not reveal whether another employee's private report exists.
        throw (New-BugReportServiceException -StatusCode 404 -Message "Bug report not found.")
    }
    return $report
}

function Add-BugReport {
    param(
        [Parameter(Mandatory = $true)][Alias("Input")]$RequestData,
        [Parameter(Mandatory = $true)]$CurrentUser,
        [AllowNull()]$NowUtc = $null
    )

    $validated = Saphir.BugReports\ConvertTo-SaphirBugReportCreateInput -Value $RequestData
    $timestamp = if ($null -ne $NowUtc) { $NowUtc.ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
    $timestampText = $timestamp.ToString('o')
    $reportId = 'bug-' + [Guid]::NewGuid().ToString('N')
    $actor = New-BugReportActorSnapshot -User $CurrentUser
    $record = [PSCustomObject][ordered]@{
        schemaVersion     = 1
        reportId          = $reportId
        revision          = 1
        title             = [string]$validated.title
        description       = [string]$validated.description
        category          = [string]$validated.category
        stepsToReproduce  = [string]$validated.stepsToReproduce
        expectedBehavior  = [string]$validated.expectedBehavior
        actualBehavior    = [string]$validated.actualBehavior
        technicalContext  = $validated.technicalContext
        status            = 'new'
        priority          = 'unranked'
        rank              = [Int64]0
        createdBy         = $actor
        createdAtUtc      = $timestampText
        updatedAtUtc      = $timestampText
        attachments       = [object[]]@()
        comments          = [object[]]@()
        history           = @([PSCustomObject][ordered]@{
            eventId      = 'event-' + [Guid]::NewGuid().ToString('N')
            type         = 'created'
            actor        = $actor
            atUtc        = $timestampText
            changedFields = [object[]]@()
        })
    }

    $lockHandle = Acquire-ResourceLock -ResourcePath $bugReportsFile
    try {
        $reports = @(Read-BugReportCollection)
        $reports += $record
        Write-JsonArrayAtomic -Path $bugReportsFile -Items $reports -Depth 16
        Clear-BugReportRuntimeCache
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
    return $record
}

function Update-BugReport {
    param(
        [Parameter(Mandatory = $true)][string]$ReportId,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [Parameter(Mandatory = $true)][Alias("Input")]$RequestData,
        [Parameter(Mandatory = $true)]$CurrentUser,
        [AllowNull()]$NowUtc = $null
    )

    if ($ExpectedRevision -lt 1) {
        throw [System.ArgumentException]::new("expectedRevision must be a positive integer.")
    }
    $patch = Saphir.BugReports\ConvertTo-SaphirBugReportPatchInput -Value $RequestData
    $normalizedId = $ReportId.Trim()
    $timestamp = if ($null -ne $NowUtc) { $NowUtc.ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
    $actor = New-BugReportActorSnapshot -User $CurrentUser
    $updatedRecord = $null
    $lockHandle = Acquire-ResourceLock -ResourcePath $bugReportsFile
    try {
        $reports = @(Read-BugReportCollection)
        $index = -1
        for ($candidateIndex = 0; $candidateIndex -lt $reports.Count; $candidateIndex++) {
            if (([string]$reports[$candidateIndex].reportId).Equals($normalizedId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $index = $candidateIndex
                break
            }
        }
        if ($index -lt 0) {
            throw (New-BugReportServiceException -StatusCode 404 -Message "Bug report not found.")
        }

        $report = $reports[$index]
        if (-not (Saphir.BugReports\Test-SaphirBugReportVisible -Report $report -User $CurrentUser)) {
            throw (New-BugReportServiceException -StatusCode 404 -Message "Bug report not found.")
        }
        if ([int]$report.revision -ne $ExpectedRevision) {
            throw (New-BugReportServiceException -StatusCode 409 -Message "This bug report changed on another workstation. Refresh it before saving.")
        }

        $isSuperAdmin = Saphir.BugReports\Test-SaphirBugReportAdministrativeUser -User $CurrentUser
        if (@($patch.administrativeFieldNames).Count -gt 0 -and -not $isSuperAdmin) {
            throw (New-BugReportServiceException -StatusCode 403 -Message "Super admin access is required to triage bug reports.")
        }
        if (@($patch.contentFieldNames).Count -gt 0 -and -not $isSuperAdmin -and
            -not (Saphir.BugReports\Test-SaphirBugReportReporterEditAllowed -Report $report -User $CurrentUser)) {
            throw (New-BugReportServiceException -StatusCode 403 -Message "This bug report can no longer be edited by its reporter.")
        }

        $changedFields = New-Object System.Collections.ArrayList
        foreach ($fieldName in @($patch.fieldNames)) {
            $oldValue = if ($report.PSObject.Properties.Name -contains $fieldName) { $report.PSObject.Properties[$fieldName].Value } else { $null }
            $newValue = $patch.fields.PSObject.Properties[$fieldName].Value
            $oldComparable = if ($fieldName -eq 'technicalContext') { $oldValue | ConvertTo-Json -Depth 5 -Compress } else { [string]$oldValue }
            $newComparable = if ($fieldName -eq 'technicalContext') { $newValue | ConvertTo-Json -Depth 5 -Compress } else { [string]$newValue }
            if ($oldComparable -ceq $newComparable) { continue }

            Set-BugReportProperty -Record $report -Name $fieldName -Value $newValue
            $change = [ordered]@{ field = $fieldName }
            if ($fieldName -in @('status', 'priority', 'rank')) {
                $change['from'] = $oldValue
                $change['to'] = $newValue
            }
            [void]$changedFields.Add([PSCustomObject]$change)
        }
        if ($changedFields.Count -eq 0) {
            throw [System.ArgumentException]::new("The bug report already contains these values.")
        }

        $nextRevision = [int]$report.revision + 1
        Set-BugReportProperty -Record $report -Name 'revision' -Value $nextRevision
        Set-BugReportProperty -Record $report -Name 'updatedAtUtc' -Value $timestamp.ToString('o')
        $history = @($report.history)
        $history += [PSCustomObject][ordered]@{
            eventId       = 'event-' + [Guid]::NewGuid().ToString('N')
            type          = 'updated'
            actor         = $actor
            atUtc         = $timestamp.ToString('o')
            changedFields = @($changedFields.ToArray())
        }
        Set-BugReportProperty -Record $report -Name 'history' -Value $history
        $reports[$index] = $report
        Write-JsonArrayAtomic -Path $bugReportsFile -Items $reports -Depth 16
        Clear-BugReportRuntimeCache
        $updatedRecord = $report
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
    return $updatedRecord
}

function Add-BugReportAttachment {
    param(
        [Parameter(Mandatory = $true)][string]$ReportId,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [AllowNull()][string]$FileName,
        [AllowNull()][string]$ContentType,
        [Parameter(Mandatory = $true)]$CurrentUser,
        [AllowNull()]$NowUtc = $null
    )

    if ($ExpectedRevision -lt 1) { throw [System.ArgumentException]::new('expectedRevision must be a positive integer.') }
    if ($Bytes.Length -lt 1) { throw [System.ArgumentException]::new('The image is empty.') }
    if ($Bytes.Length -gt $script:BugReportAttachmentMaximumBytes) {
        $exception = New-BugReportServiceException -StatusCode 413 -Message 'The image cannot exceed 8 MB.'
        throw $exception
    }
    $format = Get-BugReportAttachmentFormat -Bytes $Bytes
    $declaredType = (([string]$ContentType -split ';')[0]).Trim().ToLowerInvariant()
    if ($declaredType -eq 'image/jpg') { $declaredType = 'image/jpeg' }
    if (-not [string]::IsNullOrWhiteSpace($declaredType) -and $declaredType -ne [string]$format.contentType) {
        throw [System.ArgumentException]::new('The image content does not match its declared type.')
    }

    $normalizedId = $ReportId.Trim()
    $timestamp = if ($null -ne $NowUtc) { $NowUtc.ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
    $actor = New-BugReportActorSnapshot -User $CurrentUser
    $attachmentId = 'attachment-' + [Guid]::NewGuid().ToString('N')
    $attachmentPath = Get-BugReportAttachmentPath -ReportId $normalizedId -AttachmentId $attachmentId -Extension ([string]$format.extension)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
    $metadata = [PSCustomObject][ordered]@{
        attachmentId = $attachmentId
        fileName     = ConvertTo-BugReportAttachmentFileName -FileName $FileName
        contentType  = [string]$format.contentType
        byteLength   = [Int64]$Bytes.Length
        sha256       = $hash
        createdBy    = $actor
        createdAtUtc = $timestamp.ToString('o')
    }

    $updatedRecord = $null
    $fileWritten = $false
    $lockHandle = Acquire-ResourceLock -ResourcePath $bugReportsFile
    try {
        $reports = @(Read-BugReportCollection)
        $index = -1
        for ($candidateIndex = 0; $candidateIndex -lt $reports.Count; $candidateIndex++) {
            if (([string]$reports[$candidateIndex].reportId).Equals($normalizedId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $index = $candidateIndex
                break
            }
        }
        if ($index -lt 0) { throw (New-BugReportServiceException -StatusCode 404 -Message 'Bug report not found.') }
        $report = $reports[$index]
        if (-not (Saphir.BugReports\Test-SaphirBugReportVisible -Report $report -User $CurrentUser)) {
            throw (New-BugReportServiceException -StatusCode 404 -Message 'Bug report not found.')
        }
        if ([int]$report.revision -ne $ExpectedRevision) {
            throw (New-BugReportServiceException -StatusCode 409 -Message 'This bug report changed on another workstation. Refresh it before uploading.')
        }
        if (-not (Saphir.BugReports\Test-SaphirBugReportAdministrativeUser -User $CurrentUser) -and
            -not (Saphir.BugReports\Test-SaphirBugReportReporterEditAllowed -Report $report -User $CurrentUser)) {
            throw (New-BugReportServiceException -StatusCode 403 -Message 'Images can no longer be added to this bug report.')
        }
        if (@($report.attachments).Count -ge $script:BugReportAttachmentMaximumCount) {
            throw (New-BugReportServiceException -StatusCode 409 -Message 'A bug report can contain at most 5 images.')
        }

        Write-BugReportAttachmentFileAtomic -Path $attachmentPath -Bytes $Bytes
        $fileWritten = $true
        $attachments = @($report.attachments) + $metadata
        Set-BugReportProperty -Record $report -Name 'attachments' -Value $attachments
        Set-BugReportProperty -Record $report -Name 'revision' -Value ([int]$report.revision + 1)
        Set-BugReportProperty -Record $report -Name 'updatedAtUtc' -Value $timestamp.ToString('o')
        $history = @($report.history) + [PSCustomObject][ordered]@{
            eventId       = 'event-' + [Guid]::NewGuid().ToString('N')
            type          = 'attachmentAdded'
            actor         = $actor
            atUtc         = $timestamp.ToString('o')
            changedFields = @([PSCustomObject]@{ field = 'attachments'; attachmentId = $attachmentId })
        }
        Set-BugReportProperty -Record $report -Name 'history' -Value $history
        $reports[$index] = $report
        Write-JsonArrayAtomic -Path $bugReportsFile -Items $reports -Depth 16
        Clear-BugReportRuntimeCache
        $updatedRecord = $report
    }
    catch {
        if ($fileWritten) { Remove-Item -LiteralPath $attachmentPath -Force -ErrorAction SilentlyContinue }
        throw
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
    return [PSCustomObject][ordered]@{ report = $updatedRecord; attachment = $metadata }
}

function Get-BugReportAttachment {
    param(
        [Parameter(Mandatory = $true)][string]$ReportId,
        [Parameter(Mandatory = $true)][string]$AttachmentId,
        [Parameter(Mandatory = $true)]$CurrentUser
    )

    $report = Get-BugReport -ReportId $ReportId -CurrentUser $CurrentUser
    $metadata = @($report.attachments) | Where-Object {
        ([string]$_.attachmentId).Equals($AttachmentId.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ($null -eq $metadata) { throw (New-BugReportServiceException -StatusCode 404 -Message 'Attachment not found.') }
    $extension = switch (([string]$metadata.contentType).ToLowerInvariant()) {
        'image/png' { 'png' }
        'image/jpeg' { 'jpg' }
        'image/gif' { 'gif' }
        'image/webp' { 'webp' }
        default { throw [System.IO.InvalidDataException]::new('Invalid bug-report attachment metadata.') }
    }
    $path = Get-BugReportAttachmentPath -ReportId ([string]$report.reportId) -AttachmentId ([string]$metadata.attachmentId) -Extension $extension
    $bytes = Read-FileBytesCached -Path $path
    if ($null -eq $bytes) { throw (New-BugReportServiceException -StatusCode 404 -Message 'Attachment not found.') }
    return [PSCustomObject][ordered]@{ metadata = $metadata; bytes = [byte[]]$bytes }
}

function Add-BugReportComment {
    param(
        [Parameter(Mandatory = $true)][string]$ReportId,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [Parameter(Mandatory = $true)][Alias('Input')]$RequestData,
        [Parameter(Mandatory = $true)]$CurrentUser,
        [AllowNull()]$NowUtc = $null
    )

    if ($ExpectedRevision -lt 1) {
        throw [System.ArgumentException]::new('expectedRevision must be a positive integer.')
    }
    $validated = Saphir.BugReports\ConvertTo-SaphirBugReportCommentInput -Value $RequestData
    $normalizedId = $ReportId.Trim()
    $timestamp = if ($null -ne $NowUtc) { $NowUtc.ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
    $actor = New-BugReportActorSnapshot -User $CurrentUser
    $comment = [PSCustomObject][ordered]@{
        commentId   = 'comment-' + [Guid]::NewGuid().ToString('N')
        body        = [string]$validated.body
        createdBy   = $actor
        createdAtUtc = $timestamp.ToString('o')
    }

    $updatedRecord = $null
    $lockHandle = Acquire-ResourceLock -ResourcePath $bugReportsFile
    try {
        $reports = @(Read-BugReportCollection)
        $index = -1
        for ($candidateIndex = 0; $candidateIndex -lt $reports.Count; $candidateIndex++) {
            if (([string]$reports[$candidateIndex].reportId).Equals($normalizedId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $index = $candidateIndex
                break
            }
        }
        if ($index -lt 0) { throw (New-BugReportServiceException -StatusCode 404 -Message 'Bug report not found.') }
        $report = $reports[$index]
        if (-not (Saphir.BugReports\Test-SaphirBugReportVisible -Report $report -User $CurrentUser)) {
            throw (New-BugReportServiceException -StatusCode 404 -Message 'Bug report not found.')
        }
        if ([int]$report.revision -ne $ExpectedRevision) {
            throw (New-BugReportServiceException -StatusCode 409 -Message 'This bug report changed on another workstation. Refresh it before commenting.')
        }
        if (([string]$report.status).Equals('closed', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw (New-BugReportServiceException -StatusCode 409 -Message 'Closed bug reports cannot receive new comments.')
        }
        if (@($report.comments).Count -ge $script:BugReportCommentMaximumCount) {
            throw (New-BugReportServiceException -StatusCode 409 -Message 'This bug report reached its comment limit.')
        }

        Set-BugReportProperty -Record $report -Name 'comments' -Value (@($report.comments) + $comment)
        Set-BugReportProperty -Record $report -Name 'revision' -Value ([int]$report.revision + 1)
        Set-BugReportProperty -Record $report -Name 'updatedAtUtc' -Value $timestamp.ToString('o')
        $history = @($report.history) + [PSCustomObject][ordered]@{
            eventId       = 'event-' + [Guid]::NewGuid().ToString('N')
            type          = 'commentAdded'
            actor         = $actor
            atUtc         = $timestamp.ToString('o')
            changedFields = @([PSCustomObject]@{ field = 'comments'; commentId = [string]$comment.commentId })
        }
        Set-BugReportProperty -Record $report -Name 'history' -Value $history
        $reports[$index] = $report
        Write-JsonArrayAtomic -Path $bugReportsFile -Items $reports -Depth 16
        Clear-BugReportRuntimeCache
        $updatedRecord = $report
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
    return [PSCustomObject][ordered]@{ report = $updatedRecord; comment = $comment }
}
