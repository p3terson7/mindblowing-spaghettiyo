        # POST /employee/approval/{employeeCode}: Update approval status.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employee/approval/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"

            if (!(Test-Path -Path $dataFile)) {
                respondWithError $response 404 "Error: Employee not found."
                continue
            }

            $payload = Read-JsonRequestBody -Request $request
            $entryId = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "entryId")) { [string]$payload.entryId } else { "" }
            $date = if ($null -ne $payload) { [string]$payload.date } else { "" }
            $punchIn = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "punchIn")) { [string]$payload.punchIn } else { "" }
            $status = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "status")) { [string]$payload.status } else { "" }
            $managerMessage = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "message")) { [string]$payload.message } else { "" }

            if (([string]::IsNullOrWhiteSpace($entryId) -and (-not ($date -and $punchIn))) -or [string]::IsNullOrWhiteSpace($status)) {
                respondWithError $response 400 "Error: Missing required fields (entryId or date+punchIn, status)"
                continue
            }

            $normalizedStatus = $status.ToLowerInvariant()
            if (@("approved", "rejected") -notcontains $normalizedStatus) {
                respondWithError $response 400 "Error: status must be approved or rejected."
                continue
            }

            if ($normalizedStatus -eq "rejected" -and [string]::IsNullOrWhiteSpace($managerMessage)) {
                respondWithError $response 400 "A manager message is required when rejecting an entry."
                continue
            }

            $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                $existingData = Read-JsonArrayFile -Path $dataFile
                $entryIndex = Find-EntryIndex -Entries $existingData -EntryId $entryId -Date $date -PunchIn $punchIn
                if ($entryIndex -lt 0) {
                    respondWithError $response 404 "Error: Overtime entry not found"
                    continue
                }

                $entry = $existingData[$entryIndex]
                if (-not $entry.punchOut) {
                    respondWithError $response 400 "Open overtime sessions must be completed before they can be approved or rejected."
                    continue
                }

                $entry.status = $normalizedStatus
                if ($normalizedStatus -eq "rejected") {
                    $entry.message = $managerMessage.Trim()
                }

                Write-JsonAtomic -Path $dataFile -Value $existingData -Depth 8

                $formattedDate = (Get-Date ([string]$entry.date)).ToString("MMMM dd, yyyy")
                $employeeName = Get-EmployeeName $employeeCode
                $action = if ($normalizedStatus -eq "approved") { "Approved" } else { "Rejected" }
                $historySpan = Get-EntryHistorySpanText -StartTime ([string]$entry.punchIn) -EndTime ([string]$entry.punchOut)
                $historyEntry = "$action an entry on $formattedDate $historySpan."
                logHistory $action $historyEntry $employeeName
                Publish-DataChange -Category "employee" -Resource $employeeCode

                respondWithSuccess $response (([PSCustomObject]@{
                    message = "Entry updated successfully."
                    entryId = if ($entry.entryId) { [string]$entry.entryId } else { $null }
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                respondWithError $response 500 "Error: '$($_.Exception.Message)'"
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }
            continue
        }
