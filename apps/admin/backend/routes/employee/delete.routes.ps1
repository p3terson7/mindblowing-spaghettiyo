        # DELETE /employee/{employeeCode}: Delete an overtime entry.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/employee/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $payload = Read-JsonRequestBody -Request $request

            if (Test-CurrentUserMatchesEmployeeCode -CurrentUser $currentUser -EmployeeCode $employeeCode) {
                respondWithError $response 403 "Administrators cannot delete entries from their own employee profile."
                continue
            }

            $entryId = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "entryId")) { [string]$payload.entryId } else { "" }
            $delDate = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "date")) { [string]$payload.date } else { [string]$query["date"] }
            $delPunchIn = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "punchIn")) { [string]$payload.punchIn } else { [string]$query["punchIn"] }
            $delMessage = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "message")) { [string]$payload.message } else { [string]$query["message"] }

            if (!(Test-Path -Path $dataFile)) {
                respondWithError $response 404 "Employee not found"
                continue
            }
            if (([string]::IsNullOrWhiteSpace($entryId)) -and (-not ($delDate -and $delPunchIn))) {
                respondWithError $response 400 "Missing identifier: entryId or date and punchIn are required."
                continue
            }
            if ([string]::IsNullOrWhiteSpace($delMessage)) {
                respondWithError $response 400 "A manager message is required when deleting an entry."
                continue
            }

            $entryMutationCommitted = $false
            $entryMutationError = $null
            $postCommitWarnings = New-Object System.Collections.ArrayList
            $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                try {
                    $existingData = @(Read-JsonArrayFile -Path $dataFile)
                $entryIndex = Find-EntryIndex -Entries $existingData -EntryId $entryId -Date $delDate -PunchIn $delPunchIn
                if ($entryIndex -lt 0) {
                    respondWithError $response 404 "Entry not found"
                    continue
                }

                $entryToDelete = $existingData[$entryIndex]
                if (-not (Test-CurrentUserCanManageEntry -CurrentUser $currentUser -Entry $entryToDelete)) {
                    respondWithError $response 403 "You do not have access to this entry's project."
                    continue
                }

                $filteredData = @()
                for ($i = 0; $i -lt $existingData.Count; $i++) {
                    if ($i -ne $entryIndex) {
                        $filteredData += $existingData[$i]
                    }
                }
                    Write-JsonArrayAtomic -Path $dataFile -Items $filteredData -Depth 8
                    $entryMutationCommitted = $true
                    Release-ResourceLock -LockHandle $lockHandle
                    $lockHandle = $null

                    $historyWarning = Invoke-PostCommitActionSafely -Description "Entry deletion saved, but history logging failed" -Action {
                        $formattedDate = (Get-Date ([string]$entryToDelete.date)).ToString("MMMM dd, yyyy")
                        $employeeName = Get-EmployeeName $employeeCode
                        $historySpan = Get-EntryHistorySpanText -StartTime ([string]$entryToDelete.punchIn) -EndTime ([string]$entryToDelete.punchOut)
                        $historyEntry = "Deleted an entry on $formattedDate $historySpan. Reason: $($delMessage.Trim())"
                        logHistory "Delete" $historyEntry $employeeName -PublishChange:$false
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
                        $syncWarning = Invoke-PostCommitActionSafely -Description "Entry deletion saved, but cross-machine refresh publication failed" -Action {
                            Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
                        }
                        if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                            [void]$postCommitWarnings.Add($syncWarning)
                        }
                    }
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message = "Entry deleted successfully."
                    warnings = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 4)
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }
            continue
        }
