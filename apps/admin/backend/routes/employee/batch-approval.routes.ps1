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

            $normalizedStatus = $status.ToLowerInvariant()
            if (@("approved", "rejected") -notcontains $normalizedStatus) {
                respondWithError $response 400 "Status must be approved or rejected."
                continue
            }

            if ($normalizedStatus -eq "rejected" -and [string]::IsNullOrWhiteSpace($managerMessage)) {
                respondWithError $response 400 "A manager message is required when rejecting entries."
                continue
            }

            try {
                $updatedCount = 0
                $groupedEntries = @{}

                foreach ($entryRequest in $entries) {
                    $employeeCode = if ($entryRequest -and $entryRequest.employeeCode) { [string]$entryRequest.employeeCode } else { "" }
                    if ([string]::IsNullOrWhiteSpace($employeeCode)) {
                        continue
                    }

                    if (-not $groupedEntries.ContainsKey($employeeCode)) {
                        $groupedEntries[$employeeCode] = @()
                    }

                    $groupedEntries[$employeeCode] += $entryRequest
                }

                foreach ($employeeCode in $groupedEntries.Keys) {
                    $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"
                    if (!(Test-Path -Path $dataFile)) {
                        continue
                    }

                    $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
                    try {
                        $existingData = Read-JsonArrayFile -Path $dataFile
                        $historyEntries = @()

                        foreach ($entryRequest in @($groupedEntries[$employeeCode])) {
                            $requestEntryId = if ($entryRequest.PSObject.Properties.Name -contains "entryId") { [string]$entryRequest.entryId } else { "" }
                            $requestDate = if ($entryRequest.PSObject.Properties.Name -contains "date") { [string]$entryRequest.date } else { "" }
                            $requestPunchIn = if ($entryRequest.PSObject.Properties.Name -contains "punchIn") { [string]$entryRequest.punchIn } else { "" }
                            $entryIndex = Find-EntryIndex -Entries $existingData -EntryId $requestEntryId -Date $requestDate -PunchIn $requestPunchIn
                            if ($entryIndex -lt 0) {
                                continue
                            }

                            $entry = $existingData[$entryIndex]
                            if (-not $entry.punchOut) {
                                continue
                            }

                            $entry.status = $normalizedStatus
                            if ($normalizedStatus -eq "rejected") {
                                $entry.message = $managerMessage.Trim()
                            }

                            $action = if ($normalizedStatus -eq "approved") { "Approved" } else { "Rejected" }
                            $formattedDate = (Get-Date ([string]$entry.date)).ToString("MMMM dd, yyyy")
                            $historySpan = Get-EntryHistorySpanText -StartTime ([string]$entry.punchIn) -EndTime ([string]$entry.punchOut)
                            $historyEntries += [PSCustomObject]@{
                                action  = $action
                                message = "$action an entry on $formattedDate $historySpan."
                            }
                            $updatedCount++
                        }

                        if ($historyEntries.Count -gt 0) {
                            Write-JsonAtomic -Path $dataFile -Value $existingData -Depth 8
                            $employeeName = Get-EmployeeName $employeeCode
                            foreach ($historyEntry in $historyEntries) {
                                logHistory $historyEntry.action $historyEntry.message $employeeName
                            }
                            Publish-DataChange -Category "employee" -Resource $employeeCode
                        }
                    }
                    finally {
                        Release-ResourceLock -LockHandle $lockHandle
                    }
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message      = "Batch update completed successfully."
                    updatedCount = $updatedCount
                    status       = $normalizedStatus
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                respondWithError $response 500 "Unable to process the batch approval request: $($_.Exception.Message)"
            }
            continue
        }
