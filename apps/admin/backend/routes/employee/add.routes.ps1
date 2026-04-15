        # POST /employee/add/{employeeCode}: Add an entry for an employee.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employee/add/(\d+)$") {
            $employeeCode = $matches[1]
            $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"

            # If the employee data file doesn't exist, initialize it as an empty array.
            if (!(Test-Path -Path $dataFile)) {
                Write-JsonAtomic -Path $dataFile -Value @()
            }

            $payload = Read-JsonRequestBody -Request $request

            # Require payload to include date, punchIn, and punchOut.
            if (-not ($payload.date -and $payload.punchIn -and $payload.punchOut)) {
                respondWithError $response 400 "Missing required fields: date, punchIn, and punchOut are required."
                continue
            }

            # Require payload to include projectCode.
            if (-not $payload.projectCode) {
                respondWithError $response 400 "Missing required field: projectCode is required."
                continue
            }

            if (-not $payload.overtimeCode) {
                respondWithError $response 400 "Missing required field: overtimeCode is required."
                continue
            }

            # Validate that the provided projectCode exists in the projects list.
            $projects = Get-Projects
            $projectExists = $projects | Where-Object { $_.projectCode -eq $payload.projectCode }
            if (-not $projectExists) {
                respondWithError $response 400 "Invalid projectCode: $($payload.projectCode) does not exist."
                continue
            }

            $overtimeCodes = Get-OvertimeCodes
            $overtimeCodeExists = $overtimeCodes | Where-Object { $_.code -eq $payload.overtimeCode }
            if (-not $overtimeCodeExists) {
                respondWithError $response 400 "Invalid overtimeCode: $($payload.overtimeCode) does not exist."
                continue
            }

            $exactPunchIn = Convert-ToNormalizedTimeText -TimeText ([string]$payload.punchIn)
            $exactPunchOut = Convert-ToNormalizedTimeText -TimeText ([string]$payload.punchOut)
            if ([string]::IsNullOrWhiteSpace($exactPunchIn) -or [string]::IsNullOrWhiteSpace($exactPunchOut)) {
                respondWithError $response 400 "Punch In and Punch Out must use a valid time format."
                continue
            }

            $punchInRounded = Convert-ToNearestQuarterHourText -Date ([string]$payload.date) -TimeText $exactPunchIn
            $punchOutRounded = Convert-ToNearestQuarterHourText -Date ([string]$payload.date) -TimeText $exactPunchOut

            # Validate that punchOut is after punchIn.
            $punchInTime = [DateTime]::ParseExact("$($payload.date) $punchInRounded", "yyyy-MM-dd HH:mm:ss", $null)
            $punchOutTime = [DateTime]::ParseExact("$($payload.date) $punchOutRounded", "yyyy-MM-dd HH:mm:ss", $null)
            if ($punchOutTime -le $punchInTime) {
                respondWithError $response 400 "Punch Out must be after Punch In."
                continue
            }

            $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                $existingData = Read-JsonArrayFile -Path $dataFile

                # Create the new entry with an empty message and the projectCode.
                $newEntry = [PSCustomObject]@{
                    entryId      = New-EntryIdentifier
                    name        = Get-EmployeeName $employeeCode
                    date        = $payload.date
                    punchIn     = $punchInRounded
                    exactPunchIn = $exactPunchIn
                    punchOut    = $punchOutRounded
                    exactPunchOut = $exactPunchOut
                    overtime    = ($punchOutTime - $punchInTime).ToString("hh\:mm\:ss")
                    status      = "pending"
                    message     = ""
                    projectCode = $payload.projectCode
                    overtimeCode = $payload.overtimeCode
                }
                $existingData += $newEntry
                Write-JsonAtomic -Path $dataFile -Value $existingData -Depth 6
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }

            # Log history for adding.
            $employeeName = Get-EmployeeName $employeeCode
            $formattedDate = (Get-Date $payload.date).ToString("MMMM dd, yyyy")
            $historyMessage = "Added an entry on $formattedDate, starting at <strong>$(Format-TimeForHistory $punchInRounded)</strong> and finishing at <strong>$(Format-TimeForHistory $punchOutRounded)</strong> for project <strong>$($payload.projectCode)</strong> and overtime code <strong>$($payload.overtimeCode)</strong>."
            logHistory "Add" $historyMessage $employeeName
            Publish-DataChange -Category "employee" -Resource $employeeCode

            $responseMessage = @{
                message = "Entry added successfully."
                time    = $exactPunchIn
            }
            $responseString = $responseMessage | ConvertTo-Json -Depth 3
            $response.ContentType = "application/json"
            $response.StatusCode = 200
            $response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($responseString), 0, ([System.Text.Encoding]::UTF8.GetBytes($responseString)).Length)
            $response.Close()
            continue
        }
