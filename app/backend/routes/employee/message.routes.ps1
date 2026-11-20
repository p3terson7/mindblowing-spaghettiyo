        # NEW: PUT /employee/message/{employeeCode}: Update the message field of an overtime entry.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/employee/message/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"

            if (Test-CurrentUserMatchesEmployeeCode -CurrentUser $currentUser -EmployeeCode $employeeCode) {
                respondWithError $response 403 "Administrators cannot update messages on their own entries."
                continue
            }

            if (-not (Test-SaphirFileExists -Path $dataFile)) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $payload = Read-JsonRequestBody -Request $request
            $entryId = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "entryId")) { [string]$payload.entryId } else { "" }
            $date = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "date")) { [string]$payload.date } else { "" }
            $punchIn = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "punchIn")) { [string]$payload.punchIn } else { "" }
            $hasMessage = ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "message"))

            if (-not $hasMessage -or ([string]::IsNullOrWhiteSpace($entryId) -and
                ([string]::IsNullOrWhiteSpace($date) -or [string]::IsNullOrWhiteSpace($punchIn)))) {
                respondWithError $response 400 "Missing required fields: entryId or date+punchIn, and message are required."
                continue
            }

            $postCommitWarnings = New-Object System.Collections.ArrayList
            $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                $existingData = @(Read-JsonArrayFile -Path $dataFile)

                $entryIndex = Find-EntryIndex -Entries $existingData -EntryId $entryId -Date $date -PunchIn $punchIn
                if ($entryIndex -lt 0) {
                    respondWithError $response 404 "Entry not found"
                    continue
                }

                if (-not (Test-CurrentUserCanManageEntry -CurrentUser $currentUser -Entry $existingData[$entryIndex])) {
                    respondWithError $response 403 "You do not have access to this entry's project."
                    continue
                }

                Set-EntrySupervisorNote -Entry $existingData[$entryIndex] -Note ([string]$payload.message) -CurrentUser $currentUser | Out-Null
                Write-JsonArrayAtomic -Path $dataFile -Items $existingData -Depth 6
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }

            $syncWarning = Invoke-PostCommitActionSafely -Description "Message saved, but cross-machine refresh publication failed" -Action {
                Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
            }
            if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                [void]$postCommitWarnings.Add($syncWarning)
            }
            respondWithSuccess $response (([PSCustomObject]@{
                message = "Message updated successfully."
                warnings = @($postCommitWarnings.ToArray())
            }) | ConvertTo-Json -Depth 4)
            continue
        }
