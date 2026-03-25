        # POST /employee/approval/{employeeCode}: Update approval status.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employee/approval/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"
            
            if (!(Test-Path -Path $dataFile)) {
                respondWithError $response 404 "Error: Employee not found."
                continue
            }
            
            $payload = Read-JsonRequestBody -Request $request
            
            if (-not ($payload.date -and $payload.punchIn -and $payload.status)) {
                respondWithError $response 400 "Error: Missing required fields (date, punchIn, status)"
                continue
            }
            
            $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                $existingData = Read-JsonArrayFile -Path $dataFile
                $found = $false
                foreach ($entry in $existingData) {
                    if ($entry.date -eq $payload.date -and $entry.punchIn -eq $payload.punchIn) {
                        $entry.status = $payload.status
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    respondWithError $response 404 "Error: Overtime entry not found"
                    continue
                }
                $jsonOut = $existingData | ConvertTo-Json -Depth 3
                Write-TextAtomic -Path $dataFile -Content $jsonOut
                
                $formattedDate = (Get-Date $payload.date).ToString("MMMM dd, yyyy")
                $employeeName = Get-EmployeeName $employeeCode
                $action = if ($payload.status -eq "approved") { "Approved" } else { "Rejected" }

                $historyEntry = "$action an entry on $formattedDate starting at <strong>$(Format-TimeForHistory $payload.punchIn)</strong>."
                logHistory $action $historyEntry $employeeName
                Publish-DataChange -Category "employee" -Resource $employeeCode

                $response.ContentType = "application/json"
                $response.StatusCode = 200
                $response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($jsonOut), 0, ([System.Text.Encoding]::UTF8.GetBytes($jsonOut)).Length)
                $response.Close()
            }
            catch {
                respondWithError $response 500 "Error: '$($_.Exception.Message)'"
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }
            continue
        }
