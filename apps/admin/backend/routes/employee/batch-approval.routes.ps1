        # POST /employee/approval/batch: Approve or reject many overtime entries at once.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/employee/approval/batch") {
            $payload = Read-JsonRequestBody -Request $request
            $status = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "status")) { [string]$payload.status } else { "" }
            $entries = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "entries")) { @($payload.entries) } else { @() }
            $managerMessage = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "message")) { [string]$payload.message } else { "" }

            if ($entries.Count -eq 0) {
                respondWithError $response 400 "At least one entry is required."
                continue
            }
            $maximumBatchEntries = 500
            if ($entries.Count -gt $maximumBatchEntries) {
                respondWithError $response 413 "A batch can contain at most $maximumBatchEntries entries."
                continue
            }

            $normalizedStatus = $status.ToLowerInvariant()
            if (@("approved", "rejected") -notcontains $normalizedStatus) {
                respondWithError $response 400 "Status must be approved or rejected."
                continue
            }

            if ($normalizedStatus -eq "rejected" -and [string]::IsNullOrWhiteSpace($managerMessage)) {
                respondWithError $response 400 "A manager message is required when rejecting entries."
                continue
            }

            # Validate the complete selection before any employee file is
            # changed. Duplicate requests otherwise create duplicate history
            # records and inflate updatedCount even though only one entry changed.
            $preparedEntries = New-Object System.Collections.ArrayList
            $selectionKeys = @{}
            $selectionValidationError = ""
            for ($requestIndex = 0; $requestIndex -lt $entries.Count; $requestIndex++) {
                $entryRequest = $entries[$requestIndex]
                $employeeCode = if ($null -ne $entryRequest -and $entryRequest.PSObject.Properties.Name -contains "employeeCode") {
                    ([string]$entryRequest.employeeCode).Trim()
                }
                else {
                    ""
                }
                if ([string]::IsNullOrWhiteSpace($employeeCode) -or $employeeCode -notmatch "^\d+$") {
                    $selectionValidationError = "Every entry must contain a valid numeric employeeCode."
                    break
                }

                $requestEntryId = if ($entryRequest.PSObject.Properties.Name -contains "entryId") { ([string]$entryRequest.entryId).Trim() } else { "" }
                $requestDate = if ($entryRequest.PSObject.Properties.Name -contains "date") { ([string]$entryRequest.date).Trim() } else { "" }
                $requestPunchIn = if ($entryRequest.PSObject.Properties.Name -contains "punchIn") { ([string]$entryRequest.punchIn).Trim() } else { "" }
                if ([string]::IsNullOrWhiteSpace($requestEntryId) -and
                    ([string]::IsNullOrWhiteSpace($requestDate) -or [string]::IsNullOrWhiteSpace($requestPunchIn))) {
                    $selectionValidationError = "Every entry must contain entryId or date+punchIn."
                    break
                }

                $selectionKey = if (-not [string]::IsNullOrWhiteSpace($requestEntryId)) {
                    "{0}|id|{1}" -f $employeeCode, $requestEntryId
                }
                else {
                    "{0}|legacy|{1}|{2}" -f $employeeCode, $requestDate, $requestPunchIn
                }
                if ($selectionKeys.ContainsKey($selectionKey)) {
                    $selectionValidationError = "The batch contains the same entry more than once."
                    break
                }
                $selectionKeys[$selectionKey] = $true

                [void]$preparedEntries.Add([PSCustomObject]@{
                    requestIndex = $requestIndex
                    employeeCode = $employeeCode
                    entryId      = $requestEntryId
                    date         = $requestDate
                    punchIn      = $requestPunchIn
                })
            }
            if (-not [string]::IsNullOrWhiteSpace($selectionValidationError)) {
                respondWithError $response 400 $selectionValidationError
                continue
            }

            $containsOwnEntry = @($preparedEntries | Where-Object {
                Test-CurrentUserMatchesEmployeeCode -CurrentUser $currentUser -EmployeeCode ([string]$_.employeeCode)
            }).Count -gt 0
            if ($containsOwnEntry) {
                respondWithError $response 403 "Administrators cannot approve or reject their own entries."
                continue
            }

            try {
                $updatedCount = 0
                $postCommitWarnings = New-Object System.Collections.ArrayList
                $batchFailures = New-Object System.Collections.ArrayList
                $requestOutcomes = @{}
                $groupedEntries = @{}

                foreach ($preparedEntry in $preparedEntries) {
                    $employeeCode = [string]$preparedEntry.employeeCode
                    if (-not $groupedEntries.ContainsKey($employeeCode)) {
                        $groupedEntries[$employeeCode] = New-Object System.Collections.ArrayList
                    }
                    [void]$groupedEntries[$employeeCode].Add($preparedEntry)
                }

                $addBatchFailure = {
                    param(
                        $PreparedEntry,
                        [Parameter(Mandatory = $true)][string]$ReasonCode,
                        [Parameter(Mandatory = $true)][string]$FailureMessage
                    )

                    $outcomeKey = [string]$PreparedEntry.requestIndex
                    if ($requestOutcomes.ContainsKey($outcomeKey)) {
                        return
                    }

                    $requestOutcomes[$outcomeKey] = "failed"
                    [void]$batchFailures.Add([PSCustomObject]@{
                        index        = [int]$PreparedEntry.requestIndex
                        employeeCode = [string]$PreparedEntry.employeeCode
                        entryId      = [string]$PreparedEntry.entryId
                        date         = [string]$PreparedEntry.date
                        punchIn      = [string]$PreparedEntry.punchIn
                        reasonCode   = $ReasonCode
                        message      = $FailureMessage
                    })
                }

                $batchHistoryEntries = New-Object System.Collections.ArrayList
                $updatedEmployeeCodes = New-Object System.Collections.ArrayList
                $updatedEmployeeCodeSet = @{}

                foreach ($employeeCode in $groupedEntries.Keys) {
                    $employeeRequests = @($groupedEntries[$employeeCode])
                    try {
                        $dataFile = Get-EmployeeDataFilePath -EmployeeCode $employeeCode
                        if (!(Test-Path -Path $dataFile -PathType Leaf)) {
                            foreach ($preparedEntry in $employeeRequests) {
                                & $addBatchFailure $preparedEntry "employee_data_not_found" "The employee data file was not found."
                            }
                            continue
                        }
                        $employeeRole = Get-EmployeeRoleByCode -EmployeeCode $employeeCode
                    }
                    catch {
                        Write-Warning ("Unable to prepare batch entries for employee {0}: {1}" -f $employeeCode, $_.Exception.Message)
                        foreach ($preparedEntry in $employeeRequests) {
                            & $addBatchFailure $preparedEntry "employee_processing_failed" "The employee's entries could not be processed safely."
                        }
                        continue
                    }

                    $employeeHistoryEntries = New-Object System.Collections.ArrayList
                    $employeeUpdatedRequests = New-Object System.Collections.ArrayList
                    $lockHandle = $null
                    try {
                        $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
                        $existingData = @(Read-JsonArrayFile -Path $dataFile)
                        $entryLookup = New-EntryIndexLookup -Entries $existingData

                        foreach ($preparedEntry in $employeeRequests) {
                            $entryIndex = Find-EntryIndexFromLookup `
                                -Lookup $entryLookup `
                                -EntryId ([string]$preparedEntry.entryId) `
                                -Date ([string]$preparedEntry.date) `
                                -PunchIn ([string]$preparedEntry.punchIn)
                            if ($entryIndex -lt 0) {
                                & $addBatchFailure $preparedEntry "entry_not_found" "The overtime entry was not found. Refresh the list and try again."
                                continue
                            }

                            $entry = $existingData[$entryIndex]
                            if (-not (Test-CurrentUserCanManageEntry -CurrentUser $currentUser -Entry $entry)) {
                                & $addBatchFailure $preparedEntry "project_access_denied" "You do not have permission to manage this entry's project."
                                continue
                            }

                            if (-not (Test-CurrentUserCanApproveEmployeeRole -CurrentUser $currentUser -EmployeeRole $employeeRole)) {
                                & $addBatchFailure $preparedEntry "employee_role_denied" "You do not have permission to approve entries for this employee role."
                                continue
                            }

                            if (-not $entry.punchOut) {
                                & $addBatchFailure $preparedEntry "entry_is_open" "Open overtime sessions cannot be approved or rejected."
                                continue
                            }

                            if (([string]$entry.status).Trim().ToLowerInvariant() -eq $normalizedStatus) {
                                & $addBatchFailure $preparedEntry "already_in_status" "The entry already has the requested status."
                                continue
                            }

                            $entry.status = $normalizedStatus
                            if ($normalizedStatus -eq "rejected") {
                                $entry.message = $managerMessage.Trim()
                            }

                            $action = if ($normalizedStatus -eq "approved") { "Approved" } else { "Rejected" }
                            $formattedDate = (Get-Date ([string]$entry.date)).ToString("MMMM dd, yyyy")
                            $historySpan = Get-EntryHistorySpanText -StartTime ([string]$entry.punchIn) -EndTime ([string]$entry.punchOut)
                            [void]$employeeHistoryEntries.Add([PSCustomObject]@{
                                action  = $action
                                message = "$action an entry on $formattedDate $historySpan."
                            })
                            [void]$employeeUpdatedRequests.Add($preparedEntry)
                        }

                        if ($employeeUpdatedRequests.Count -gt 0) {
                            Write-JsonArrayAtomic -Path $dataFile -Items $existingData -Depth 8
                            foreach ($preparedEntry in $employeeUpdatedRequests) {
                                $requestOutcomes[[string]$preparedEntry.requestIndex] = "updated"
                            }
                            $updatedCount += $employeeUpdatedRequests.Count
                            if (-not $updatedEmployeeCodeSet.ContainsKey($employeeCode)) {
                                $updatedEmployeeCodeSet[$employeeCode] = $true
                                [void]$updatedEmployeeCodes.Add($employeeCode)
                            }
                        }
                    }
                    catch {
                        Write-Warning ("Unable to process batch entries for employee {0}: {1}" -f $employeeCode, $_.Exception.Message)
                        foreach ($preparedEntry in $employeeRequests) {
                            & $addBatchFailure $preparedEntry "employee_processing_failed" "The employee's entries could not be processed safely."
                        }
                        $employeeHistoryEntries = New-Object System.Collections.ArrayList
                    }
                    finally {
                        Release-ResourceLock -LockHandle $lockHandle
                    }

                    if ($employeeHistoryEntries.Count -gt 0) {
                        # The employee mutation is already durable at this
                        # point. A damaged optional name lookup must therefore
                        # not turn a committed update into an HTTP 500.
                        $employeeName = $employeeCode
                        try {
                            $resolvedEmployeeName = [string](Get-EmployeeName $employeeCode)
                            if (-not [string]::IsNullOrWhiteSpace($resolvedEmployeeName)) {
                                $employeeName = $resolvedEmployeeName
                            }
                        }
                        catch {
                            $nameLookupWarning = "Batch approvals saved, but employee name lookup failed: $($_.Exception.Message)"
                            Write-Warning $nameLookupWarning
                            [void]$postCommitWarnings.Add($nameLookupWarning)
                        }
                        foreach ($historyEntry in $employeeHistoryEntries) {
                            [void]$batchHistoryEntries.Add([PSCustomObject]@{
                                action       = [string]$historyEntry.action
                                message      = [string]$historyEntry.message
                                employeeName = $employeeName
                            })
                        }
                    }
                }

                # Every request must have an explicit outcome. This is a final
                # guard against a future branch accidentally returning success
                # after silently skipping an item.
                foreach ($preparedEntry in $preparedEntries) {
                    if (-not $requestOutcomes.ContainsKey([string]$preparedEntry.requestIndex)) {
                        & $addBatchFailure $preparedEntry "not_processed" "The entry was not processed."
                    }
                }

                if ($batchHistoryEntries.Count -gt 0) {
                    $historyWarning = Invoke-PostCommitActionSafely -Description "Batch approvals saved, but history logging failed" -Action {
                        Add-HistoryEntries -Entries @($batchHistoryEntries.ToArray()) -PublishChange:$false | Out-Null
                    }
                    if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                        [void]$postCommitWarnings.Add($historyWarning)
                    }
                }

                if ($updatedEmployeeCodes.Count -gt 0) {
                    $syncResource = if ($updatedEmployeeCodes.Count -eq 1) { [string]$updatedEmployeeCodes[0] } else { "*" }
                    $syncWarning = Invoke-PostCommitActionSafely -Description "Batch approvals saved, but cross-machine refresh publication failed" -Action {
                        Publish-DataChange -Category "employee" -Resource $syncResource -AffectedEmployeeCodes @($updatedEmployeeCodes.ToArray()) | Out-Null
                    }
                    if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                        [void]$postCommitWarnings.Add($syncWarning)
                    }
                }

                $requestedCount = $preparedEntries.Count
                $failedCount = $batchFailures.Count
                $outcome = if ($updatedCount -eq $requestedCount) {
                    "success"
                }
                elseif ($updatedCount -gt 0) {
                    "partial"
                }
                else {
                    "none"
                }
                $resultMessage = if ($outcome -eq "success") {
                    "All requested entries were updated."
                }
                elseif ($outcome -eq "partial") {
                    "Batch update partially completed: $updatedCount of $requestedCount entries were updated."
                }
                else {
                    "No entries were updated. Refresh the list and review the failure details."
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message        = $resultMessage
                    outcome        = $outcome
                    requestedCount = $requestedCount
                    updatedCount   = $updatedCount
                    failedCount    = $failedCount
                    failures       = @($batchFailures.ToArray() | Sort-Object index)
                    status         = $normalizedStatus
                    warnings       = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 6)
            }
            catch {
                Write-Warning ("Unable to process the batch approval request: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to process the batch approval request."
            }
            continue
        }
