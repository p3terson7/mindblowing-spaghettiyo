        if ($request.Url.AbsolutePath -eq "/self/profile" -and $request.HttpMethod -eq "GET") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            respondWithSuccess $response (($currentUser | Select-Object username, displayName, role, employeeCode, mustChangePassword) | ConvertTo-Json -Depth 6)
            continue
        }

        if ($request.Url.AbsolutePath -eq "/self/entries" -and $request.HttpMethod -eq "GET") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$currentUser.employeeCode)) {
                respondWithError $response 403 "Employee access is required."
                continue
            }

            $dataFile = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $currentUser.employeeCode)
            if (!(Test-Path -Path $dataFile)) {
                respondWithSuccess $response "[]"
                continue
            }

            $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)
            respondWithSuccess $response ($entries | ConvertTo-Json -Depth 6)
            continue
        }

        if ($request.Url.AbsolutePath -eq "/self/bootstrap" -and $request.HttpMethod -eq "GET") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$currentUser.employeeCode)) {
                respondWithError $response 403 "Employee access is required."
                continue
            }

            $bootstrapPayload = Get-SelfBootstrapModel -EmployeeCode ([string]$currentUser.employeeCode)
            respondWithSuccess $response ($bootstrapPayload | ConvertTo-Json -Depth 6)
            continue
        }

        if ($request.Url.AbsolutePath -eq "/self/options" -and $request.HttpMethod -eq "GET") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            $optionsPayload = [PSCustomObject]@{
                projects      = @(Get-ActiveProjects)
                overtimeCodes = @(Get-OvertimeCodes)
                paymentOptions = @(Get-PaymentOptions)
                reasonCodes    = @(Get-ReasonCodes)
            }

            respondWithSuccess $response ($optionsPayload | ConvertTo-Json -Depth 6)
            continue
        }

        if ($request.Url.AbsolutePath -eq "/self/punch" -and $request.HttpMethod -eq "POST") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$currentUser.employeeCode)) {
                respondWithError $response 403 "Employee access is required."
                continue
            }

            try {
                $payload = Read-JsonRequestBody -Request $request
                if ($null -eq $payload -or -not ($payload.type -in @("in", "out"))) {
                    respondWithError $response 400 "Punch type must be 'in' or 'out'."
                    continue
                }

                if ($payload.type -eq "in") {
                    $projectCode = [string]$payload.projectCode
                    $overtimeCode = [string]$payload.overtimeCode
                    $paymentOption = [string]$payload.paymentOption
                    $reasonCode = [string]$payload.reasonCode

                    if ([string]::IsNullOrWhiteSpace($projectCode)) {
                        respondWithError $response 400 "Project selection is required before starting overtime."
                        continue
                    }

                    if ([string]::IsNullOrWhiteSpace($paymentOption)) {
                        respondWithError $response 400 "Payment selection is required before starting overtime."
                        continue
                    }

                    $projects = @(Get-ActiveProjects)
                    if (-not ($projects | Where-Object { [string]$_.projectCode -eq $projectCode })) {
                        respondWithError $response 400 "Invalid project code: $projectCode."
                        continue
                    }

                    $overtimeCodes = @(Get-OvertimeCodes)
                    if (-not (Test-OptionCode -Options $overtimeCodes -Code $overtimeCode -AllowBlank $true)) {
                        respondWithError $response 400 "Invalid overtime code: $overtimeCode."
                        continue
                    }

                    $paymentOptions = @(Get-PaymentOptions)
                    if (-not (Test-OptionCode -Options $paymentOptions -Code $paymentOption -AllowBlank $false)) {
                        respondWithError $response 400 "Invalid payment option: $paymentOption."
                        continue
                    }

                    $reasonCodes = @(Get-ReasonCodes)
                    if (-not (Test-OptionCode -Options $reasonCodes -Code $reasonCode -AllowBlank $true)) {
                        respondWithError $response 400 "Invalid reason code: $reasonCode."
                        continue
                    }
                }

                $employeeCode = [string]$currentUser.employeeCode
                $dataFile = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $employeeCode)
                if (!(Test-Path -Path $dataFile)) {
                    Write-JsonAtomic -Path $dataFile -Value @()
                }

                $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
                try {
                    $existingData = Read-JsonArrayFile -Path $dataFile
                    $sortedEntries = @(
                        $existingData | Sort-Object @{
                            Expression = {
                                try {
                                    [DateTime]::ParseExact(("{0} {1}" -f $_.date, $_.punchIn), "yyyy-MM-dd HH:mm:ss", $null)
                                }
                                catch {
                                    [DateTime]::MinValue
                                }
                            }
                        }
                    )
                    $lastEntry = $sortedEntries | Select-Object -Last 1
                    $activeEntry = @($sortedEntries | Where-Object { $_.punchIn -and -not $_.punchOut -and -not (Test-EntryForgottenClockOut -Entry $_) }) | Select-Object -Last 1

                    $now = Get-Date
                    $exactNow = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $now.Hour -Minute $now.Minute -Second 0
                    $todayText = $exactNow.ToString("yyyy-MM-dd")
                    $exactNowText = $exactNow.ToString("HH:mm:ss")
                    $roundedNowText = Convert-ToNearestQuarterHourText -Date $todayText -TimeText $exactNowText
                    $requiresClockOutReview = $false
                    $reviewEntryDate = ""
                    $punchResultMessage = "Punch updated successfully."

                    if ($payload.type -eq "in") {
                        if ($activeEntry) {
                            if ([string]$activeEntry.date -eq $todayText) {
                                respondWithError $response 400 "You must punch out before punching in again."
                                continue
                            }

                            Set-EntryForgottenClockOutReview -Entry $activeEntry -AttemptDate $todayText -AttemptTime $exactNowText
                            $requiresClockOutReview = $true
                            $reviewEntryDate = [string]$activeEntry.date
                        }

                        $existingData += [PSCustomObject]@{
                            entryId      = New-EntryIdentifier
                            name        = Get-EmployeeName $employeeCode
                            date        = $todayText
                            punchIn     = $roundedNowText
                            exactPunchIn = $exactNowText
                            punchOut    = $null
                            exactPunchOut = $null
                            overtime    = $null
                            status      = "pending"
                            message     = ""
                            projectCode = $projectCode
                            overtimeCode = $overtimeCode
                            paymentOption = $paymentOption
                            reasonCode = $reasonCode
                        }
                    }
                    else {
                        if (-not $activeEntry) {
                            respondWithError $response 400 "No active punch-in record found."
                            continue
                        }

                        if ([string]$activeEntry.date -ne $todayText) {
                            Set-EntryForgottenClockOutReview -Entry $activeEntry -AttemptDate $todayText -AttemptTime $exactNowText
                            $requiresClockOutReview = $true
                            $reviewEntryDate = [string]$activeEntry.date
                            $punchResultMessage = "Previous-day clock-out requires supervisor review."
                        }
                        else {
                            $activeEntry.exactPunchOut = $exactNowText
                            $activeEntry.punchOut = $roundedNowText
                            $punchInTime = [DateTime]::ParseExact("$($activeEntry.date) $($activeEntry.punchIn)", "yyyy-MM-dd HH:mm:ss", $null)
                            $punchOutTime = [DateTime]::ParseExact("$($activeEntry.date) $($activeEntry.punchOut)", "yyyy-MM-dd HH:mm:ss", $null)
                            $activeEntry.overtime = ($punchOutTime - $punchInTime).ToString("hh\:mm\:ss")
                        }
                    }

                    Write-JsonAtomic -Path $dataFile -Value $existingData -Depth 6
                }
                finally {
                    Release-ResourceLock -LockHandle $lockHandle
                }

                Publish-DataChange -Category "employee" -Resource $employeeCode

                $result = [PSCustomObject]@{
                    message = $punchResultMessage
                    time    = $exactNowText
                    requiresClockOutReview = $requiresClockOutReview
                    reviewEntryDate = $reviewEntryDate
                }
                respondWithSuccess $response ($result | ConvertTo-Json -Depth 6)
            }
            catch {
                respondWithError $response 500 "Unable to process punch: $($_.Exception.Message)"
            }
            continue
        }
