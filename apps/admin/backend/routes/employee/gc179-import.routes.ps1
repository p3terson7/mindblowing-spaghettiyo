        # POST /employee/gc179-import/preview: Parse an FDF and return the entries that would be imported.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/employee/gc179-import/preview") {
            try {
                $payload = Read-JsonRequestBody -Request $request
                $employeeCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "employeeCode") { ([string]$payload.employeeCode).Trim() } else { "" }
                $projectCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "projectCode") { ([string]$payload.projectCode).Trim() } else { "" }
                $fdfContent = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "fdfContent") { [string]$payload.fdfContent } else { "" }
                $fileName = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "fileName") { [string]$payload.fileName } else { "" }
                $status = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "status") { [string]$payload.status } else { "approved" }
                $managerMessage = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "managerMessage") { [string]$payload.managerMessage } else { "" }

                if ([string]::IsNullOrWhiteSpace($employeeCode)) {
                    respondWithError $response 400 "Employee code is required."
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($projectCode)) {
                    respondWithError $response 400 "Project code is required because GC179 files do not store SAPHIR project codes."
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($fdfContent)) {
                    respondWithError $response 400 "FDF content is required."
                    continue
                }

                $employeeUser = Get-EmployeeUserByCode -EmployeeCode $employeeCode
                if ($null -eq $employeeUser) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }

                if (-not (Test-CurrentUserCanModifyProjectCode -CurrentUser $currentUser -ProjectCode $projectCode)) {
                    respondWithError $response 403 "You can view this project, but only assigned project admins can import entries for it."
                    continue
                }

                $projectExists = @(Get-ActiveProjects | Where-Object { [string]$_.projectCode -eq $projectCode }).Count -gt 0
                if (-not $projectExists) {
                    respondWithError $response 400 "Invalid projectCode: $projectCode does not exist."
                    continue
                }

                $preview = New-Gc179ImportPreview -FdfContent $fdfContent -EmployeeCode $employeeCode -ProjectCode $projectCode -FileName $fileName -Status $status -ManagerMessage $managerMessage
                respondWithSuccess $response ($preview | ConvertTo-Json -Depth 10)
            }
            catch {
                respondWithError $response 400 $_.Exception.Message
            }
            continue
        }

        # POST /employee/gc179-import/commit: Import previously previewed GC179 FDF entries into SAPHIR data.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/employee/gc179-import/commit") {
            try {
                $payload = Read-JsonRequestBody -Request $request
                $employeeCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "employeeCode") { ([string]$payload.employeeCode).Trim() } else { "" }
                $projectCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "projectCode") { ([string]$payload.projectCode).Trim() } else { "" }
                $fdfContent = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "fdfContent") { [string]$payload.fdfContent } else { "" }
                $fileName = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "fileName") { [string]$payload.fileName } else { "" }
                $status = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "status") { [string]$payload.status } else { "approved" }
                $managerMessage = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "managerMessage") { [string]$payload.managerMessage } else { "" }
                $skipDuplicates = $true
                if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "skipDuplicates") {
                    $skipDuplicates = Convert-ToBooleanFlag -Value $payload.skipDuplicates
                }

                if ([string]::IsNullOrWhiteSpace($employeeCode)) {
                    respondWithError $response 400 "Employee code is required."
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($projectCode)) {
                    respondWithError $response 400 "Project code is required because GC179 files do not store SAPHIR project codes."
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($fdfContent)) {
                    respondWithError $response 400 "FDF content is required."
                    continue
                }

                $employeeUser = Get-EmployeeUserByCode -EmployeeCode $employeeCode
                if ($null -eq $employeeUser) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }

                if (Test-CurrentUserMatchesEmployeeCode -CurrentUser $currentUser -EmployeeCode $employeeCode) {
                    respondWithError $response 403 "Administrators cannot import GC179 entries into their own employee profile."
                    continue
                }

                if (-not (Test-CurrentUserCanModifyProjectCode -CurrentUser $currentUser -ProjectCode $projectCode)) {
                    respondWithError $response 403 "You can view this project, but only assigned project admins can import entries for it."
                    continue
                }

                $projectExists = @(Get-ActiveProjects | Where-Object { [string]$_.projectCode -eq $projectCode }).Count -gt 0
                if (-not $projectExists) {
                    respondWithError $response 400 "Invalid projectCode: $projectCode does not exist."
                    continue
                }

                $normalizedStatus = ([string]$status).Trim().ToLowerInvariant()
                if ($normalizedStatus -ne "approved" -and $normalizedStatus -ne "pending" -and $normalizedStatus -ne "rejected") {
                    $normalizedStatus = "approved"
                }

                $employeeRole = Get-EffectiveUserRole -UserRecord $employeeUser
                if ($normalizedStatus -ne "pending" -and -not (Test-CurrentUserCanApproveEmployeeRole -CurrentUser $currentUser -EmployeeRole $employeeRole)) {
                    respondWithError $response 403 "Only super admins can import already-approved or rejected entries for admin users."
                    continue
                }

                $preview = New-Gc179ImportPreview -FdfContent $fdfContent -EmployeeCode $employeeCode -ProjectCode $projectCode -FileName $fileName -Status $normalizedStatus -ManagerMessage $managerMessage
                if ($preview.entryCount -le 0) {
                    respondWithError $response 400 "No importable GC179 entries were found."
                    continue
                }

                $invalidRows = @()
                $overtimeCodes = Get-OvertimeCodes
                $paymentOptions = Get-PaymentOptions
                $reasonCodes = Get-ReasonCodes
                foreach ($entry in @($preview.entries)) {
                    $rowNumber = ([int]$entry.sourceRow) + 1
                    if (-not (Test-OptionCode -Options $overtimeCodes -Code ([string]$entry.overtimeCode) -AllowBlank $true)) {
                        $invalidRows += "Row $rowNumber has invalid overtime code '$($entry.overtimeCode)'."
                    }
                    if (-not (Test-OptionCode -Options $paymentOptions -Code ([string]$entry.paymentOption) -AllowBlank $false)) {
                        $invalidRows += "Row $rowNumber has missing or invalid payment option."
                    }
                    if (-not (Test-OptionCode -Options $reasonCodes -Code ([string]$entry.reasonCode) -AllowBlank $true)) {
                        $invalidRows += "Row $rowNumber has invalid reason code '$($entry.reasonCode)'."
                    }
                }

                if ($invalidRows.Count -gt 0) {
                    respondWithError $response 400 ($invalidRows -join " ")
                    continue
                }

                $employeeName = if ($employeeUser.displayName) { [string]$employeeUser.displayName } else { Get-EmployeeName $employeeCode }
                $result = Import-Gc179PreviewEntries -Preview $preview -EmployeeCode $employeeCode -EmployeeName $employeeName -SourceFile $fileName -SkipDuplicates:$skipDuplicates

                if ($result.importedCount -gt 0) {
                    $message = "Imported <strong>$($result.importedCount)</strong> GC179 entr$(if ($result.importedCount -eq 1) { "y" } else { "ies" }) for month <strong>$($preview.monthKey)</strong> into project <strong>$projectCode</strong>."
                    if ($result.skippedDuplicateCount -gt 0) {
                        $message += " Skipped <strong>$($result.skippedDuplicateCount)</strong> duplicate entr$(if ($result.skippedDuplicateCount -eq 1) { "y" } else { "ies" })."
                    }
                    logHistory "Import" $message $employeeName
                }

                $responsePayload = [PSCustomObject]@{
                    message               = "GC179 import completed."
                    employeeCode          = $employeeCode
                    employeeName          = $employeeName
                    projectCode           = $projectCode
                    monthKey              = $preview.monthKey
                    importedCount         = $result.importedCount
                    skippedDuplicateCount = $result.skippedDuplicateCount
                    entryIds              = @($result.entryIds)
                }
                respondWithSuccess $response ($responsePayload | ConvertTo-Json -Depth 6)
            }
            catch {
                respondWithError $response 400 $_.Exception.Message
            }
            continue
        }
