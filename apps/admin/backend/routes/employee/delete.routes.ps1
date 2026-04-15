        # DELETE /employee/{employeeCode}: Delete an overtime entry.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/employee/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $payload = Read-JsonRequestBody -Request $request

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

            $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                $existingData = Read-JsonArrayFile -Path $dataFile
                $entryIndex = Find-EntryIndex -Entries $existingData -EntryId $entryId -Date $delDate -PunchIn $delPunchIn
                if ($entryIndex -lt 0) {
                    respondWithError $response 404 "Entry not found"
                    continue
                }

                $entryToDelete = $existingData[$entryIndex]
                $filteredData = @()
                for ($i = 0; $i -lt $existingData.Count; $i++) {
                    if ($i -ne $entryIndex) {
                        $filteredData += $existingData[$i]
                    }
                }
                Write-JsonAtomic -Path $dataFile -Value $filteredData -Depth 8

                $formattedDate = (Get-Date ([string]$entryToDelete.date)).ToString("MMMM dd, yyyy")
                $employeeName = Get-EmployeeName $employeeCode
                $historySpan = Get-EntryHistorySpanText -StartTime ([string]$entryToDelete.punchIn) -EndTime ([string]$entryToDelete.punchOut)
                $historyEntry = "Deleted an entry on $formattedDate $historySpan. Reason: $($delMessage.Trim())"
                logHistory "Delete" $historyEntry $employeeName
                Publish-DataChange -Category "employee" -Resource $employeeCode
                respondWithSuccess $response '{ "message": "Entry deleted successfully." }'
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }
            continue
        }
