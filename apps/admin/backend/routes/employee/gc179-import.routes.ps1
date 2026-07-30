function Get-Gc179ImportRouteContext {
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [AllowNull()][string]$ProjectCode,
        [AllowNull()][string]$Status,
        [Parameter(Mandatory = $true)]$CurrentUser,
        [bool]$RequireProject = $true
    )

    if ([string]::IsNullOrWhiteSpace($EmployeeCode)) {
        return [PSCustomObject]@{ errorStatus = 400; error = "Employee code is required." }
    }

    $employeeUser = Get-EmployeeUserByCode -EmployeeCode $EmployeeCode
    if ($null -eq $employeeUser) {
        return [PSCustomObject]@{ errorStatus = 404; error = "Employee not found." }
    }
    if ([bool]$employeeUser.disabled) {
        return [PSCustomObject]@{ errorStatus = 400; error = "GC179 entries cannot be imported for an archived employee." }
    }
    if (Test-CurrentUserMatchesEmployeeCode -CurrentUser $CurrentUser -EmployeeCode $EmployeeCode) {
        return [PSCustomObject]@{ errorStatus = 403; error = "Administrators cannot import or undo GC179 entries in their own employee profile." }
    }

    $normalizedStatus = ""
    try {
        $normalizedStatus = ConvertTo-Gc179ImportStatus -Status $Status
    }
    catch {
        return [PSCustomObject]@{ errorStatus = 400; error = $_.Exception.Message }
    }

    if ($RequireProject) {
        if ([string]::IsNullOrWhiteSpace($ProjectCode)) {
            return [PSCustomObject]@{ errorStatus = 400; error = "Project code is required because GC179 files do not store SAPHIR project codes." }
        }
        if (-not (Test-CurrentUserCanModifyProjectCode -CurrentUser $CurrentUser -ProjectCode $ProjectCode)) {
            return [PSCustomObject]@{ errorStatus = 403; error = "You can view this project, but only assigned project admins can import entries for it." }
        }
        $projectExists = @(Get-ActiveProjects | Where-Object { [string]$_.projectCode -eq $ProjectCode }).Count -gt 0
        if (-not $projectExists) {
            return [PSCustomObject]@{ errorStatus = 400; error = "Invalid projectCode: $ProjectCode does not exist or is archived." }
        }

        $employeeRole = Get-EffectiveUserRole -UserRecord $employeeUser
        if ($normalizedStatus -ne "pending" -and -not (Test-CurrentUserCanApproveEmployeeRole -CurrentUser $CurrentUser -EmployeeRole $employeeRole)) {
            return [PSCustomObject]@{ errorStatus = 403; error = "Only super admins can import already-approved or rejected entries for admin users." }
        }
    }

    $employeeName = if ($employeeUser.displayName) { [string]$employeeUser.displayName } else { [string](Get-EmployeeName $EmployeeCode) }
    return [PSCustomObject]@{
        errorStatus      = 0
        error            = ""
        employeeUser     = $employeeUser
        employeeName     = $employeeName
        normalizedStatus = $normalizedStatus
    }
}

if (-not [bool]$gc179ImportEnabled -and $request.Url.AbsolutePath -match "^/employee/gc179-import/") {
    respondWithError $response 404 "GC179 import is not enabled on this server."
    continue
}

# POST /employee/gc179-import/preview: parse and fully validate an FDF before any write.
if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/employee/gc179-import/preview") {
    if ([long]$request.ContentLength64 -gt 1572864) {
        respondWithError $response 413 "The GC179 import request is too large."
        continue
    }
    try {
        $payload = Read-JsonRequestBody -Request $request
        $employeeCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "employeeCode") { ([string]$payload.employeeCode).Trim() } else { "" }
        $projectCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "projectCode") { ([string]$payload.projectCode).Trim() } else { "" }
        $fdfContent = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "fdfContent") { [string]$payload.fdfContent } else { "" }
        $fileName = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "fileName") { [System.IO.Path]::GetFileName([string]$payload.fileName) } else { "" }
        $status = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "status") { [string]$payload.status } else { "pending" }
        $managerMessage = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "managerMessage") { [string]$payload.managerMessage } else { "" }
        $confirmIdentity = ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "confirmIdentity" -and (Convert-ToBooleanFlag -Value $payload.confirmIdentity))

        $routeContext = Get-Gc179ImportRouteContext -EmployeeCode $employeeCode -ProjectCode $projectCode -Status $status -CurrentUser $currentUser
        if ([int]$routeContext.errorStatus -gt 0) {
            respondWithError $response ([int]$routeContext.errorStatus) ([string]$routeContext.error)
            continue
        }

        Assert-Gc179ImportPayload -FdfContent $fdfContent -FileName $fileName -ManagerMessage $managerMessage
        $preview = New-Gc179ImportPreview -FdfContent $fdfContent -EmployeeCode $employeeCode -ProjectCode $projectCode -FileName $fileName -Status ([string]$routeContext.normalizedStatus) -ManagerMessage $managerMessage
        $preview = Complete-Gc179ImportPreview -Preview $preview -EmployeeUser $routeContext.employeeUser -EmployeeCode $employeeCode -EmployeeName ([string]$routeContext.employeeName) -FileName $fileName -ConfirmIdentity:$confirmIdentity -SkipDuplicates:$true
        respondWithSuccess $response ($preview | ConvertTo-Json -Depth 12)
    }
    catch {
        respondWithError $response 400 $_.Exception.Message
    }
    continue
}

# POST /employee/gc179-import/commit: reparse and revalidate the original FDF, then import selected rows.
if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/employee/gc179-import/commit") {
    if ([long]$request.ContentLength64 -gt 1572864) {
        respondWithError $response 413 "The GC179 import request is too large."
        continue
    }
    try {
        $payload = Read-JsonRequestBody -Request $request
        $employeeCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "employeeCode") { ([string]$payload.employeeCode).Trim() } else { "" }
        $projectCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "projectCode") { ([string]$payload.projectCode).Trim() } else { "" }
        $fdfContent = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "fdfContent") { [string]$payload.fdfContent } else { "" }
        $fileName = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "fileName") { [System.IO.Path]::GetFileName([string]$payload.fileName) } else { "" }
        $status = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "status") { [string]$payload.status } else { "pending" }
        $managerMessage = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "managerMessage") { [string]$payload.managerMessage } else { "" }
        $confirmIdentity = ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "confirmIdentity" -and (Convert-ToBooleanFlag -Value $payload.confirmIdentity))

        if ($null -eq $payload -or -not ($payload.PSObject.Properties.Name -contains "selectedSourceRows")) {
            respondWithError $response 400 "Select at least one previewed GC179 row to import."
            continue
        }
        $selectedSourceRows = @()
        $selectedRowsAreValid = $true
        foreach ($sourceRowValue in @($payload.selectedSourceRows)) {
            $sourceRow = 0
            if (-not [int]::TryParse([string]$sourceRowValue, [ref]$sourceRow)) {
                $selectedRowsAreValid = $false
                break
            }
            $selectedSourceRows += $sourceRow
        }
        if (-not $selectedRowsAreValid) {
            respondWithError $response 400 "Selected GC179 rows must use numeric row identifiers."
            continue
        }
        if ($selectedSourceRows.Count -eq 0) {
            respondWithError $response 400 "Select at least one previewed GC179 row to import."
            continue
        }

        $routeContext = Get-Gc179ImportRouteContext -EmployeeCode $employeeCode -ProjectCode $projectCode -Status $status -CurrentUser $currentUser
        if ([int]$routeContext.errorStatus -gt 0) {
            respondWithError $response ([int]$routeContext.errorStatus) ([string]$routeContext.error)
            continue
        }

        Assert-Gc179ImportPayload -FdfContent $fdfContent -FileName $fileName -ManagerMessage $managerMessage
        $preview = New-Gc179ImportPreview -FdfContent $fdfContent -EmployeeCode $employeeCode -ProjectCode $projectCode -FileName $fileName -Status ([string]$routeContext.normalizedStatus) -ManagerMessage $managerMessage
        $preview = Complete-Gc179ImportPreview -Preview $preview -EmployeeUser $routeContext.employeeUser -EmployeeCode $employeeCode -EmployeeName ([string]$routeContext.employeeName) -FileName $fileName -ConfirmIdentity:$confirmIdentity -SkipDuplicates:$true

        if (@($preview.validationErrors).Count -gt 0) {
            respondWithError $response 400 (@($preview.validationErrors) -join " ")
            continue
        }
        if ([string]$preview.identity.status -eq "unverified" -and -not [bool]$preview.identity.confirmed) {
            respondWithError $response 400 "Confirm that this GC179 belongs to the selected employee before importing."
            continue
        }

        $selectedEntries = @(Get-Gc179SelectedImportEntries -Preview $preview -SelectedSourceRows $selectedSourceRows)
        $selectedPreview = [PSCustomObject]@{ entries = @($selectedEntries) }
        $sourceHash = Get-Gc179ImportSha256 -Value $fdfContent
        $importedBy = if ($currentUser.PSObject.Properties.Name -contains "username") { [string]$currentUser.username } else { "" }
        $projectReferenceLockHandle = Acquire-ProjectReferenceLock
        try {
            if (-not (Test-ActiveProjectCodeFromDisk -ProjectCode $projectCode)) {
                throw "The selected project is no longer active. Refresh the preview and choose another project."
            }
            if (-not (Test-CurrentUserCanModifyActiveProjectCodeFromDisk -CurrentUser $currentUser -ProjectCode $projectCode)) {
                throw "Your permission for the selected project changed. Refresh the preview and try again."
            }

            $result = Import-Gc179PreviewEntries -Preview $selectedPreview -EmployeeCode $employeeCode -EmployeeName ([string]$routeContext.employeeName) -SourceFile $fileName -SourceHash $sourceHash -ImportedBy $importedBy -SkipDuplicates:$true -PublishChange:$false
        }
        finally {
            Release-ResourceLock -LockHandle $projectReferenceLockHandle
        }

        $responseWarnings = @($result.warnings)
        if ($result.importedCount -gt 0) {
            $historyMessage = "Imported <strong>$($result.importedCount)</strong> GC179 entr$(if ($result.importedCount -eq 1) { "y" } else { "ies" }) for month <strong>$($preview.monthKey)</strong> into project <strong>$projectCode</strong>. Batch: <strong>$($result.batchId)</strong>."
            if ($result.skippedDuplicateCount -gt 0) {
                $historyMessage += " Skipped <strong>$($result.skippedDuplicateCount)</strong> duplicate entr$(if ($result.skippedDuplicateCount -eq 1) { "y" } else { "ies" })."
            }
            try {
                logHistory "Import" $historyMessage ([string]$routeContext.employeeName) -PublishChange:$false
            }
            catch {
                $responseWarnings += "Entries were saved, but the history log could not be updated."
            }

            try {
                Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
            }
            catch {
                $responseWarnings += "Entries were saved, but other open SAPHIR windows may need a manual refresh."
            }
        }

        $responsePayload = [PSCustomObject]@{
            message               = "GC179 import completed."
            employeeCode          = $employeeCode
            employeeName          = [string]$routeContext.employeeName
            projectCode           = $projectCode
            monthKey              = $preview.monthKey
            batchId               = $result.batchId
            importedCount         = $result.importedCount
            skippedDuplicateCount = $result.skippedDuplicateCount
            entryIds              = @($result.entryIds)
            warnings              = @($responseWarnings)
        }
        respondWithSuccess $response ($responsePayload | ConvertTo-Json -Depth 8)
    }
    catch {
        respondWithError $response 400 $_.Exception.Message
    }
    continue
}

# POST /employee/gc179-import/undo: remove an unchanged import batch atomically.
if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/employee/gc179-import/undo") {
    try {
        $payload = Read-JsonRequestBody -Request $request
        $employeeCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "employeeCode") { ([string]$payload.employeeCode).Trim() } else { "" }
        $batchId = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "batchId") { ([string]$payload.batchId).Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($batchId)) {
            respondWithError $response 400 "GC179 import batch ID is required."
            continue
        }

        $routeContext = Get-Gc179ImportRouteContext -EmployeeCode $employeeCode -ProjectCode "" -Status "pending" -CurrentUser $currentUser -RequireProject:$false
        if ([int]$routeContext.errorStatus -gt 0) {
            respondWithError $response ([int]$routeContext.errorStatus) ([string]$routeContext.error)
            continue
        }

        $result = Undo-Gc179ImportBatch -EmployeeCode $employeeCode -BatchId $batchId -CurrentUser $currentUser -PublishChange:$false
        $responseWarnings = @($result.warnings)
        try {
            logHistory "Undo import" "Undid GC179 import batch <strong>$batchId</strong> and removed <strong>$($result.undoneCount)</strong> entr$(if ($result.undoneCount -eq 1) { "y" } else { "ies" })." ([string]$routeContext.employeeName) -PublishChange:$false
        }
        catch {
            $responseWarnings += "The undo was saved, but the history log could not be updated."
        }
        try {
            Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
        }
        catch {
            $responseWarnings += "The undo was saved, but other open SAPHIR windows may need a manual refresh."
        }

        $responsePayload = [PSCustomObject]@{
            message      = "GC179 import was undone."
            employeeCode = $employeeCode
            employeeName = [string]$routeContext.employeeName
            batchId      = $result.batchId
            undoneCount  = $result.undoneCount
            entryIds     = @($result.entryIds)
            projectCodes = @($result.projectCodes)
            warnings     = @($responseWarnings)
        }
        respondWithSuccess $response ($responsePayload | ConvertTo-Json -Depth 8)
    }
    catch {
        respondWithError $response 400 $_.Exception.Message
    }
    continue
}
