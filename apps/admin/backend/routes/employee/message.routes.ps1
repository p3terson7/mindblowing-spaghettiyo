        # NEW: PUT /employee/message/{employeeCode}: Update the message field of an overtime entry.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/employee/message/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"

            if (!(Test-Path -Path $dataFile)) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $payload = Read-JsonRequestBody -Request $request

            # Require payload to include date, punchIn, and message.
            if (-not ($payload.date -and $payload.punchIn -and ($payload.PSObject.Properties.Name -contains "message"))) {
                respondWithError $response 400 "Missing required fields: date, punchIn, and message are required."
                continue
            }

            $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                $existingData = Read-JsonArrayFile -Path $dataFile

                $found = $false
                $accessDenied = $false
                for ($i = 0; $i -lt $existingData.Count; $i++) {
                    if ($existingData[$i].date -eq $payload.date -and $existingData[$i].punchIn -eq $payload.punchIn) {
                        if (-not (Test-CurrentUserCanManageEntry -CurrentUser $currentUser -Entry $existingData[$i])) {
                            $accessDenied = $true
                            break
                        }
                        $existingData[$i].message = $payload.message
                        $found = $true
                        break
                    }
                }
                if ($accessDenied) {
                    respondWithError $response 403 "You do not have access to this entry's project."
                    continue
                }
                if (-not $found) {
                    respondWithError $response 404 "Entry not found"
                    continue
                }
                Write-JsonAtomic -Path $dataFile -Value $existingData -Depth 6
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }

            Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
            respondWithSuccess $response '{ "message": "Message updated successfully." }'
            continue
        }
