        # PUT /employee/{employeeCode}: Update overtime entry.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/employee/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"

            if (!(Test-Path -Path $dataFile)) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $payload = Read-JsonRequestBody -Request $request

            # Require payload to include the date and the original punchIn (stable identifier).
            if (-not ($payload.date -and $payload.originalPunchIn)) {
                respondWithError $response 400 "Missing required identifier: date and originalPunchIn are required."
                continue
            }

            # Determine new punchIn value.
            $newPunchIn = $payload.newPunchIn
            if (-not $newPunchIn) { $newPunchIn = $payload.originalPunchIn }

            # Optionally update punchOut if provided.
            $newPunchOut = $payload.punchOut

            # Round times to the minute (set seconds to "00").
            $newPunchIn = (($newPunchIn -split ":")[0] + ":" + ($newPunchIn -split ":")[1] + ":00")
            if ($newPunchOut) {
                $newPunchOut = (($newPunchOut -split ":")[0] + ":" + ($newPunchOut -split ":")[1] + ":00")
            }

            # If projectCode is provided in the payload, validate it.
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

                # Find the entry index by matching date and original punchIn.
                $foundIndex = -1
                for ($i = 0; $i -lt $existingData.Count; $i++) {
                    if ($existingData[$i].date -eq $payload.date -and $existingData[$i].punchIn -eq $payload.originalPunchIn) {
                        $foundIndex = $i
                        break
                    }
                }
                if ($foundIndex -eq -1) {
                    respondWithError $response 404 "Entry not found"
                    continue
                }

                # Initialize an array for individual update messages.
                $messages = @()

                # Update punchIn if changed.
                if ($payload.originalPunchIn -ne $newPunchIn) {
                    $existingData[$foundIndex].punchIn = $newPunchIn
                    $messages += "Punch In from <strong>$(Format-TimeForHistory $payload.originalPunchIn)</strong> to <strong>$(Format-TimeForHistory $newPunchIn)</strong>."
                }

                # Update punchOut if provided.
                if ($newPunchOut) {
                    if ($existingData[$foundIndex].punchOut -and $existingData[$foundIndex].punchOut -ne $newPunchOut) {
                        $messages += "Punch Out from <strong>$(Format-TimeForHistory $existingData[$foundIndex].punchOut)</strong> to <strong>$(Format-TimeForHistory $newPunchOut)</strong>."
                    }
                    elseif (-not $existingData[$foundIndex].punchOut) {
                        $messages += "Punch Out recorded at <strong>$(Format-TimeForHistory $newPunchOut)</strong>."
                    }
                    $existingData[$foundIndex].punchOut = $newPunchOut
                }

                # Update projectCode if provided.
                if ($payload.PSObject.Properties.Name -contains "projectCode") {
                    $existingData[$foundIndex].projectCode = $payload.projectCode
                    $messages += "Project Code updated."
                }

                if ($payload.PSObject.Properties.Name -contains "overtimeCode") {
                    $existingData[$foundIndex].overtimeCode = $payload.overtimeCode
                    $messages += "Overtime Code updated."
                }

                # Recalculate overtime if both punchIn and punchOut exist.
                if ($existingData[$foundIndex].punchIn -and $existingData[$foundIndex].punchOut) {
                    $punchInTime = [DateTime]::ParseExact("$($existingData[$foundIndex].date) $($existingData[$foundIndex].punchIn)", "yyyy-MM-dd HH:mm:ss", $null)
                    $punchOutTime = [DateTime]::ParseExact("$($existingData[$foundIndex].date) $($existingData[$foundIndex].punchOut)", "yyyy-MM-dd HH:mm:ss", $null)
                    $existingData[$foundIndex].overtime = ($punchOutTime - $punchInTime).ToString("hh\:mm\:ss")
                }

                # Save the updated data.
                Write-JsonAtomic -Path $dataFile -Value $existingData -Depth 6

                # Build the history log message.
                $employeeName = Get-EmployeeName $employeeCode
                $formattedDate = (Get-Date $payload.date).ToString("MMMM dd, yyyy")
                if ($messages.Count -eq 0) {
                    $finalMessage = "Entry on $formattedDate updated successfully."
                }
                else {
                    $finalMessage = "Updated an entry on $formattedDate, " + ($messages -join " ")
                }
                logHistory "Update" $finalMessage $employeeName
                Publish-DataChange -Category "employee" -Resource $employeeCode

                respondWithSuccess $response ('{ "message": "' + ($messages -join "<br>") + '" }')
            }
            catch {
                respondWithError $response 500 "Error: '$($_.Exception.Message)'"
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }
            continue
        }
