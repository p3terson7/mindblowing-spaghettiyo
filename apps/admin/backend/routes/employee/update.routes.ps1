        # PUT /employee/{employeeCode}: Update overtime entry.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/employee/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"

            if (!(Test-Path -Path $dataFile)) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $payload = Read-JsonRequestBody -Request $request
            $entryId = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "entryId")) { [string]$payload.entryId } else { "" }
            $date = if ($null -ne $payload) { [string]$payload.date } else { "" }
            $originalPunchIn = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "originalPunchIn")) { [string]$payload.originalPunchIn } else { "" }
            $managerMessage = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "message")) { [string]$payload.message } else { "" }

            if ([string]::IsNullOrWhiteSpace($date) -or ([string]::IsNullOrWhiteSpace($entryId) -and [string]::IsNullOrWhiteSpace($originalPunchIn))) {
                respondWithError $response 400 "Missing required identifier: date and entryId/originalPunchIn are required."
                continue
            }

            if ([string]::IsNullOrWhiteSpace($managerMessage)) {
                respondWithError $response 400 "A manager message is required when updating an entry."
                continue
            }

            if ($payload.PSObject.Properties.Name -contains "projectCode") {
                if (-not $payload.projectCode) {
                    respondWithError $response 400 "If provided, projectCode cannot be empty."
                    continue
                }
                $projects = Get-Projects
                $projectExists = $projects | Where-Object { $_.projectCode -eq $payload.projectCode }
                if (-not $projectExists) {
                    respondWithError $response 400 "Invalid projectCode: $($payload.projectCode) does not exist."
                    continue
                }
            }

            if ($payload.PSObject.Properties.Name -contains "overtimeCode") {
                if (-not $payload.overtimeCode) {
                    respondWithError $response 400 "If provided, overtimeCode cannot be empty."
                    continue
                }
                $overtimeCodes = Get-OvertimeCodes
                $overtimeCodeExists = $overtimeCodes | Where-Object { $_.code -eq $payload.overtimeCode }
                if (-not $overtimeCodeExists) {
                    respondWithError $response 400 "Invalid overtimeCode: $($payload.overtimeCode) does not exist."
                    continue
                }
            }

            $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                $existingData = Read-JsonArrayFile -Path $dataFile
                $foundIndex = Find-EntryIndex -Entries $existingData -EntryId $entryId -Date $date -PunchIn $originalPunchIn
                if ($foundIndex -eq -1) {
                    respondWithError $response 404 "Entry not found"
                    continue
                }

                $existingEntry = $existingData[$foundIndex]
                if (-not (Get-EntryIdentifierValue -Entry $existingEntry)) {
                    $existingEntry | Add-Member -NotePropertyName entryId -NotePropertyValue (New-EntryIdentifier) -Force
                }

                $originalRoundedPunchIn = [string]$existingEntry.punchIn
                $originalRoundedPunchOut = if ($existingEntry.punchOut) { [string]$existingEntry.punchOut } else { $null }
                $originalProjectCode = if ($existingEntry.projectCode) { [string]$existingEntry.projectCode } else { "" }
                $originalOvertimeCode = if ($existingEntry.overtimeCode) { [string]$existingEntry.overtimeCode } else { "" }

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

                if ($payload.PSObject.Properties.Name -contains "projectCode" -and $originalProjectCode -ne [string]$payload.projectCode) {
                    $messages += "Project Code updated."
                }

                if ($payload.PSObject.Properties.Name -contains "overtimeCode" -and $originalOvertimeCode -ne [string]$payload.overtimeCode) {
                    $messages += "Overtime Code updated."
                }

                $existingEntry.punchIn = $newRoundedPunchIn
                $existingEntry.exactPunchIn = $newExactPunchIn
                $existingEntry.punchOut = $newRoundedPunchOut
                $existingEntry.exactPunchOut = $newExactPunchOut
                if ($payload.PSObject.Properties.Name -contains "projectCode") {
                    $existingEntry.projectCode = [string]$payload.projectCode
                }
                if ($payload.PSObject.Properties.Name -contains "overtimeCode") {
                    $existingEntry.overtimeCode = [string]$payload.overtimeCode
                }
                $existingEntry.message = $managerMessage.Trim()
                Update-EntryComputedOvertime -Entry $existingEntry

                Write-JsonAtomic -Path $dataFile -Value $existingData -Depth 8

                $employeeName = Get-EmployeeName $employeeCode
                $formattedDate = (Get-Date $date).ToString("MMMM dd, yyyy")
                $historySpan = Get-EntryHistorySpanText -StartTime ([string]$existingEntry.punchIn) -EndTime ([string]$existingEntry.punchOut)
                if ($messages.Count -eq 0) {
                    $finalMessage = "Updated an entry on $formattedDate $historySpan."
                }
                else {
                    $finalMessage = "Updated an entry on $formattedDate $historySpan. " + ($messages -join " ")
                }
                logHistory "Update" $finalMessage $employeeName
                Publish-DataChange -Category "employee" -Resource $employeeCode

                respondWithSuccess $response (([PSCustomObject]@{
                    message = ($messages -join "<br>")
                    entryId = [string]$existingEntry.entryId
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
