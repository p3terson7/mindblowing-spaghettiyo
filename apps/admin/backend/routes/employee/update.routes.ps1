        # PUT /employee/{employeeCode}: Update overtime entry.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/employee/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"

            if (Test-CurrentUserMatchesEmployeeCode -CurrentUser $currentUser -EmployeeCode $employeeCode) {
                respondWithError $response 403 "Administrators cannot update entries in their own employee profile."
                continue
            }

            if (!(Test-Path -Path $dataFile)) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $payload = Read-JsonRequestBody -Request $request
            $entryId = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "entryId")) { [string]$payload.entryId } else { "" }
            $date = if ($null -ne $payload) { [string]$payload.date } else { "" }
            $originalPunchIn = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "originalPunchIn")) { [string]$payload.originalPunchIn } else { "" }
            $managerMessage = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "message")) { [string]$payload.message } else { "" }
            $statusProvided = ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "status"))
            $requestedStatus = ""
            $payloadEntryType = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "entryType")) { ([string]$payload.entryType).Trim().ToLowerInvariant() } else { "" }
            $workCommentProvided = ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "workComment"))
            $payloadWorkComment = if ($workCommentProvided) { ([string]$payload.workComment).Trim() } else { "" }
            $diverseSummaryProvided = ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "diverseSummary"))
            $payloadDiverseSummary = if ($diverseSummaryProvided) { ([string]$payload.diverseSummary).Trim() } else { "" }

            if ([string]::IsNullOrWhiteSpace($date) -or ([string]::IsNullOrWhiteSpace($entryId) -and [string]::IsNullOrWhiteSpace($originalPunchIn))) {
                respondWithError $response 400 "Missing required identifier: date and entryId/originalPunchIn are required."
                continue
            }

            $normalizedDate = Convert-ToNormalizedDateText -DateText $date
            if ([string]::IsNullOrWhiteSpace($normalizedDate)) {
                respondWithError $response 400 "Date must use the yyyy-MM-dd format."
                continue
            }
            $date = $normalizedDate

            if ([string]::IsNullOrWhiteSpace($managerMessage)) {
                respondWithError $response 400 "A manager message is required when updating an entry."
                continue
            }

            if ($statusProvided) {
                $requestedStatus = ([string]$payload.status).Trim().ToLowerInvariant()
                if (@("approved", "rejected", "pending") -notcontains $requestedStatus) {
                    respondWithError $response 400 "If provided, status must be approved, rejected, or pending."
                    continue
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($payloadEntryType) -and @("overtime", "diverse") -notcontains $payloadEntryType) {
                respondWithError $response 400 "If provided, entryType must be overtime or diverse."
                continue
            }

            if ($payloadEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "projectCode") {
                if (-not $payload.projectCode) {
                    respondWithError $response 400 "If provided, projectCode cannot be empty."
                    continue
                }
                $projects = Get-ActiveProjects
                $projectExists = $projects | Where-Object { $_.projectCode -eq $payload.projectCode }
                if (-not $projectExists) {
                    respondWithError $response 400 "Invalid projectCode: $($payload.projectCode) does not exist."
                    continue
                }

                if (-not (Test-CurrentUserCanModifyProjectCode -CurrentUser $currentUser -ProjectCode ([string]$payload.projectCode)) ) {
                    respondWithError $response 403 "You can view project $($payload.projectCode), but only assigned project admins can modify entries for it."
                    continue
                }
            }

            if ($payloadEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "overtimeCode") {
                $overtimeCodes = Get-OvertimeCodes
                if (-not (Test-OptionCode -Options $overtimeCodes -Code ([string]$payload.overtimeCode) -AllowBlank $true)) {
                    respondWithError $response 400 "Invalid overtimeCode: $($payload.overtimeCode) does not exist."
                    continue
                }
            }

            if ($payloadEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "paymentOption") {
                if (-not $payload.paymentOption) {
                    respondWithError $response 400 "If provided, paymentOption cannot be empty."
                    continue
                }
                $paymentOptions = Get-PaymentOptions
                if (-not (Test-OptionCode -Options $paymentOptions -Code ([string]$payload.paymentOption) -AllowBlank $false)) {
                    respondWithError $response 400 "Invalid paymentOption: $($payload.paymentOption) does not exist."
                    continue
                }
            }

            if ($payloadEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "reasonCode") {
                $reasonCodes = Get-ReasonCodes
                if (-not (Test-OptionCode -Options $reasonCodes -Code ([string]$payload.reasonCode) -AllowBlank $true)) {
                    respondWithError $response 400 "Invalid reasonCode: $($payload.reasonCode) does not exist."
                    continue
                }
            }

            $entryMutationCommitted = $false
            $entryMutationError = $null
            $postCommitWarnings = New-Object System.Collections.ArrayList
            $lockHandle = $null
            $projectReferenceLockHandle = $null
            try {
                if ($payloadEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "projectCode") {
                    $projectReferenceLockHandle = Acquire-ProjectReferenceLock
                    if (-not (Test-ActiveProjectCodeFromDisk -ProjectCode ([string]$payload.projectCode))) {
                        respondWithError $response 409 "The selected project is no longer active. Refresh and choose another project."
                        continue
                    }
                    if (-not (Test-CurrentUserCanModifyActiveProjectCodeFromDisk -CurrentUser $currentUser -ProjectCode ([string]$payload.projectCode))) {
                        respondWithError $response 403 "Your permission for the selected project changed. Refresh and try again."
                        continue
                    }
                }

                $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
                try {
                    $existingData = @(Read-JsonArrayFile -Path $dataFile)
                $foundIndex = Find-EntryIndex -Entries $existingData -EntryId $entryId -Date $date -PunchIn $originalPunchIn
                if ($foundIndex -eq -1) {
                    respondWithError $response 404 "Entry not found"
                    continue
                }

                $existingEntry = $existingData[$foundIndex]
                if (-not (Get-EntryIdentifierValue -Entry $existingEntry)) {
                    $existingEntry | Add-Member -NotePropertyName entryId -NotePropertyValue (New-EntryIdentifier) -Force
                }

                if (-not (Test-CurrentUserCanManageEntry -CurrentUser $currentUser -Entry $existingEntry)) {
                    respondWithError $response 403 "You do not have access to this entry's project."
                    continue
                }

                $originalRoundedPunchIn = [string]$existingEntry.punchIn
                $originalRoundedPunchOut = if ($existingEntry.punchOut) { [string]$existingEntry.punchOut } else { $null }
                $originalProjectCode = if ($existingEntry.projectCode) { [string]$existingEntry.projectCode } else { "" }
                $originalOvertimeCode = if ($existingEntry.overtimeCode) { [string]$existingEntry.overtimeCode } else { "" }
                $originalPaymentOption = if ($existingEntry.paymentOption) { [string]$existingEntry.paymentOption } else { "cash" }
                $originalReasonCode = if ($existingEntry.reasonCode) { [string]$existingEntry.reasonCode } else { "" }
                $workCommentExists = ($existingEntry.PSObject.Properties.Name -contains "workComment")
                $originalWorkComment = if ($workCommentExists) { ([string]$existingEntry.workComment).Trim() } else { "" }
                $originalStatus = if ($existingEntry.status) { ([string]$existingEntry.status).ToLowerInvariant() } else { "pending" }
                $existingEntryType = if ($existingEntry.PSObject.Properties.Name -contains "entryType" -and -not [string]::IsNullOrWhiteSpace([string]$existingEntry.entryType)) { ([string]$existingEntry.entryType).Trim().ToLowerInvariant() } else { "overtime" }
                $originalDiverseReason = if ($existingEntry.PSObject.Properties.Name -contains "diverseReason") { [string]$existingEntry.diverseReason } else { "" }
                $originalDiverseSummary = if ($existingEntry.PSObject.Properties.Name -contains "diverseSummary") { ([string]$existingEntry.diverseSummary).Trim() } else { "" }

                if (-not [string]::IsNullOrWhiteSpace($payloadEntryType) -and $payloadEntryType -ne $existingEntryType) {
                    respondWithError $response 400 "Entry type cannot be changed after creation."
                    continue
                }

                if ($existingEntryType -eq "diverse" -and $payload.PSObject.Properties.Name -contains "diverseReason" -and [string]::IsNullOrWhiteSpace([string]$payload.diverseReason)) {
                    respondWithError $response 400 "Diverse entries require a reason."
                    continue
                }

                $submittedComment = if ($existingEntryType -eq "diverse") { $payloadDiverseSummary } else { $payloadWorkComment }
                $originalComment = if ($existingEntryType -eq "diverse") { $originalDiverseSummary } else { $originalWorkComment }
                $commentProvided = if ($existingEntryType -eq "diverse") { $diverseSummaryProvided } else { $workCommentProvided }
                if ($commentProvided -and $submittedComment.Length -gt 1000 -and $submittedComment -ne $originalComment) {
                    respondWithError $response 400 "Work comments cannot exceed 1000 characters."
                    continue
                }

                if ($statusProvided -and $requestedStatus -ne $originalStatus) {
                    $employeeRole = Get-EmployeeRoleByCode -EmployeeCode $employeeCode
                    if (-not (Test-CurrentUserCanApproveEmployeeRole -CurrentUser $currentUser -EmployeeRole $employeeRole)) {
                        respondWithError $response 403 "Only super admins can change the approval status of admin entries."
                        continue
                    }
                }

                $newExactPunchIn = if ($payload.newPunchIn) {
                    Convert-ToNormalizedTimeText -TimeText ([string]$payload.newPunchIn)
                }
                else {
                    Get-EntryExactPunchInText -Entry $existingEntry
                }

                if ([string]::IsNullOrWhiteSpace($newExactPunchIn)) {
                    respondWithError $response 400 "Punch In must use a valid time format."
                    continue
                }

                $newExactPunchOut = $null
                if ($payload.PSObject.Properties.Name -contains "punchOut") {
                    if ([string]::IsNullOrWhiteSpace([string]$payload.punchOut)) {
                        $newExactPunchOut = $null
                    }
                    else {
                        $newExactPunchOut = Convert-ToNormalizedTimeText -TimeText ([string]$payload.punchOut)
                        if ([string]::IsNullOrWhiteSpace($newExactPunchOut)) {
                            respondWithError $response 400 "Punch Out must use a valid time format."
                            continue
                        }
                    }
                }
                else {
                    $newExactPunchOut = Get-EntryExactPunchOutText -Entry $existingEntry
                }

                $newRoundedPunchIn = Convert-ToNearestQuarterHourText -Date $date -TimeText $newExactPunchIn
                $newRoundedPunchOut = if ($newExactPunchOut) { Convert-ToNearestQuarterHourText -Date $date -TimeText $newExactPunchOut } else { $null }

                if ($newRoundedPunchOut) {
                    $punchInTime = [DateTime]::ParseExact("$date $newRoundedPunchIn", "yyyy-MM-dd HH:mm:ss", $null)
                    $punchOutTime = [DateTime]::ParseExact("$date $newRoundedPunchOut", "yyyy-MM-dd HH:mm:ss", $null)
                    if ($punchOutTime -le $punchInTime) {
                        respondWithError $response 400 "Punch Out must be after Punch In."
                        continue
                    }
                }

                if ($statusProvided -and $requestedStatus -ne "pending" -and -not $newRoundedPunchOut) {
                    respondWithError $response 400 "Open overtime sessions must be completed before they can be approved or rejected."
                    continue
                }

                if ($existingEntryType -eq "diverse" -and $newRoundedPunchOut) {
                    $nextDiverseSummary = if ($diverseSummaryProvided) { $payloadDiverseSummary } else { $originalDiverseSummary }
                    if ([string]::IsNullOrWhiteSpace($nextDiverseSummary)) {
                        respondWithError $response 400 "Completed diverse entries require a work summary."
                        continue
                    }
                }
                if ($existingEntryType -ne "diverse" -and $newRoundedPunchOut -and $workCommentProvided -and
                    -not [string]::IsNullOrWhiteSpace($originalWorkComment) -and [string]::IsNullOrWhiteSpace($payloadWorkComment)) {
                    respondWithError $response 400 "An existing work comment cannot be cleared from a completed overtime entry."
                    continue
                }

                $messages = @()
                if ($originalRoundedPunchIn -ne $newRoundedPunchIn) {
                    $messages += "Punch In from <strong>$(Format-TimeForHistory $originalRoundedPunchIn)</strong> to <strong>$(Format-TimeForHistory $newRoundedPunchIn)</strong>."
                }

                if ($newRoundedPunchOut) {
                    if ($originalRoundedPunchOut -and $originalRoundedPunchOut -ne $newRoundedPunchOut) {
                        $messages += "Punch Out from <strong>$(Format-TimeForHistory $originalRoundedPunchOut)</strong> to <strong>$(Format-TimeForHistory $newRoundedPunchOut)</strong>."
                    }
                    elseif (-not $originalRoundedPunchOut) {
                        $messages += "Punch Out recorded at <strong>$(Format-TimeForHistory $newRoundedPunchOut)</strong>."
                    }
                }

                if ($existingEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "projectCode" -and $originalProjectCode -ne [string]$payload.projectCode) {
                    $messages += "Project Code updated."
                }

                if ($existingEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "overtimeCode" -and $originalOvertimeCode -ne [string]$payload.overtimeCode) {
                    $messages += "Overtime Code updated."
                }

                if ($existingEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "paymentOption" -and $originalPaymentOption -ne [string]$payload.paymentOption) {
                    $messages += "Payment option updated."
                }

                if ($existingEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "reasonCode" -and $originalReasonCode -ne [string]$payload.reasonCode) {
                    $messages += "Reason code updated."
                }

                if ($existingEntryType -ne "diverse" -and $workCommentProvided -and $originalWorkComment -ne $payloadWorkComment) {
                    $messages += "Work comment updated."
                }

                if ($existingEntryType -eq "diverse" -and $payload.PSObject.Properties.Name -contains "diverseReason" -and $originalDiverseReason -ne [string]$payload.diverseReason) {
                    $messages += "Diverse reason updated."
                }

                if ($existingEntryType -eq "diverse" -and $diverseSummaryProvided -and $originalDiverseSummary -ne $payloadDiverseSummary) {
                    $messages += "Diverse summary updated."
                }

                if ($statusProvided -and $originalStatus -ne $requestedStatus) {
                    $messages += "Status changed from <strong>$originalStatus</strong> to <strong>$requestedStatus</strong>."
                }

                $existingEntry.punchIn = $newRoundedPunchIn
                $existingEntry.exactPunchIn = $newExactPunchIn
                $existingEntry.punchOut = $newRoundedPunchOut
                $existingEntry.exactPunchOut = $newExactPunchOut
                if ($newRoundedPunchOut) {
                    Clear-EntryForgottenClockOutReview -Entry $existingEntry
                }
                if ($existingEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "projectCode") {
                    $existingEntry.projectCode = [string]$payload.projectCode
                }
                if ($existingEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "overtimeCode") {
                    Set-EntryPropertyValue -Entry $existingEntry -Name "overtimeCode" -Value ([string]$payload.overtimeCode)
                }
                if ($existingEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "paymentOption") {
                    Set-EntryPropertyValue -Entry $existingEntry -Name "paymentOption" -Value ([string]$payload.paymentOption)
                }
                if ($existingEntryType -ne "diverse" -and $payload.PSObject.Properties.Name -contains "reasonCode") {
                    Set-EntryPropertyValue -Entry $existingEntry -Name "reasonCode" -Value ([string]$payload.reasonCode)
                }
                if ($existingEntryType -ne "diverse" -and $workCommentProvided -and
                    ($workCommentExists -or -not [string]::IsNullOrWhiteSpace($payloadWorkComment))) {
                    Set-EntryPropertyValue -Entry $existingEntry -Name "workComment" -Value $payloadWorkComment
                }
                if ($existingEntryType -eq "diverse") {
                    Set-EntryPropertyValue -Entry $existingEntry -Name "entryType" -Value "diverse"
                    Set-EntryPropertyValue -Entry $existingEntry -Name "projectCode" -Value ""
                    Set-EntryPropertyValue -Entry $existingEntry -Name "overtimeCode" -Value ""
                    Set-EntryPropertyValue -Entry $existingEntry -Name "paymentOption" -Value ""
                    Set-EntryPropertyValue -Entry $existingEntry -Name "reasonCode" -Value ""
                    if ($payload.PSObject.Properties.Name -contains "diverseReason") {
                        Set-EntryPropertyValue -Entry $existingEntry -Name "diverseReason" -Value ([string]$payload.diverseReason)
                    }
                    if ($diverseSummaryProvided) {
                        Set-EntryPropertyValue -Entry $existingEntry -Name "diverseSummary" -Value $payloadDiverseSummary
                    }
                }
                if ($statusProvided) {
                    $existingEntry.status = $requestedStatus
                }
                $existingEntry.message = $managerMessage.Trim()
                Update-EntryComputedOvertime -Entry $existingEntry

                    Write-JsonArrayAtomic -Path $dataFile -Items $existingData -Depth 8
                    $entryMutationCommitted = $true
                    Release-ResourceLock -LockHandle $lockHandle
                    $lockHandle = $null
                    Release-ResourceLock -LockHandle $projectReferenceLockHandle
                    $projectReferenceLockHandle = $null

                    $historyWarning = Invoke-PostCommitActionSafely -Description "Entry update saved, but history logging failed" -Action {
                        $employeeName = Get-EmployeeName $employeeCode
                        $formattedDate = (Get-Date $date).ToString("MMMM dd, yyyy")
                        $historySpan = Get-EntryHistorySpanText -StartTime ([string]$existingEntry.punchIn) -EndTime ([string]$existingEntry.punchOut)
                        if ($messages.Count -eq 0) {
                            $finalMessage = "Updated an entry on $formattedDate $historySpan."
                        }
                        else {
                            $finalMessage = "Updated an entry on $formattedDate $historySpan. " + ($messages -join " ")
                        }
                        logHistory "Update" $finalMessage $employeeName -PublishChange:$false
                    }
                    if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                        [void]$postCommitWarnings.Add($historyWarning)
                    }
                }
                catch {
                    $entryMutationError = $_
                    throw
                }
                finally {
                    if ($entryMutationCommitted) {
                        $syncWarning = Invoke-PostCommitActionSafely -Description "Entry update saved, but cross-machine refresh publication failed" -Action {
                            Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
                        }
                        if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                            [void]$postCommitWarnings.Add($syncWarning)
                        }
                    }
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message = ($messages -join "<br>")
                    entryId = [string]$existingEntry.entryId
                    warnings = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                Write-Warning ("Unable to update employee entry: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to update the employee entry."
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
                Release-ResourceLock -LockHandle $projectReferenceLockHandle
            }
            continue
        }
