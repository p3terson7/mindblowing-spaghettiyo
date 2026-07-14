        if ($request.Url.AbsolutePath -eq "/self/profile" -and $request.HttpMethod -eq "GET") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            $profilePayload = [PSCustomObject]@{
                username           = [string]$currentUser.username
                displayName        = [string]$currentUser.displayName
                role               = [string]$currentUser.role
                employeeCode       = [string]$currentUser.employeeCode
                mustChangePassword = [bool]$currentUser.mustChangePassword
                timeEntryTypes     = @(Get-EmployeeTimeEntryTypesFromUserRecord -UserRecord $currentUser)
                gc179Profile       = Get-Gc179ProfileFromUserRecord -UserRecord $currentUser
            }
            respondWithSuccess $response ($profilePayload | ConvertTo-Json -Depth 6)
            continue
        }

        if ($request.Url.AbsolutePath -eq "/self/gc179-profile" -and $request.HttpMethod -eq "PUT") {
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
                $profilePayload = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "gc179Profile")) { $payload.gc179Profile } else { $payload }

                if (-not (Set-EmployeeUserGc179Profile -EmployeeCode ([string]$currentUser.employeeCode) -Gc179Profile $profilePayload)) {
                    respondWithError $response 500 "Unable to update GC179 profile."
                    continue
                }

                $updatedUser = Get-EmployeeUserByCode -EmployeeCode ([string]$currentUser.employeeCode)
                $updatedProfile = Get-Gc179ProfileFromUserRecord -UserRecord $updatedUser
                Publish-DataChange -Category "auth" -Resource ([string]$currentUser.employeeCode) | Out-Null

                respondWithSuccess $response (([PSCustomObject]@{
                    message      = "GC179 profile updated successfully."
                    gc179Profile = $updatedProfile
                }) | ConvertTo-Json -Depth 6)
            }
            catch {
                respondWithError $response 500 "Unable to update GC179 profile: $($_.Exception.Message)"
            }
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
            $entriesJson = if ($entries.Count -gt 0) {
                $entries | ConvertTo-Json -Depth 6
            }
            else {
                "[]"
            }
            respondWithSuccess $response $entriesJson
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

        if ($request.Url.AbsolutePath -eq "/self/gc179-open" -and $request.HttpMethod -eq "POST") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$currentUser.employeeCode)) {
                respondWithError $response 403 "Employee access is required."
                continue
            }

            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $monthKey = [string]$query["month"]
            try {
                $launch = Start-Gc179LocalExport -EmployeeCode ([string]$currentUser.employeeCode) -MonthKey $monthKey
                respondWithSuccess $response ($launch | ConvertTo-Json -Depth 6)
            }
            catch {
                respondWithError $response 400 $_.Exception.Message
            }
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
                timeEntryTypes = if (-not [string]::IsNullOrWhiteSpace([string]$currentUser.employeeCode)) { @(Get-EmployeeTimeEntryTypesByCode -EmployeeCode ([string]$currentUser.employeeCode)) } else { @("overtime") }
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

                $employeeCode = [string]$currentUser.employeeCode
                $entryType = "overtime"
                $diverseReason = ""
                $diverseSummary = ""

                if ($payload.type -eq "in") {
                    if ($payload.PSObject.Properties.Name -contains "entryType" -and -not [string]::IsNullOrWhiteSpace([string]$payload.entryType)) {
                        $entryType = ([string]$payload.entryType).Trim().ToLowerInvariant()
                    }

                    if (@("overtime", "diverse") -notcontains $entryType) {
                        respondWithError $response 400 "Invalid entry type: $entryType."
                        continue
                    }

                    if (-not (Test-EmployeeCanPunchEntryType -EmployeeCode $employeeCode -EntryType $entryType)) {
                        respondWithError $response 403 "This employee is not allowed to punch this time category."
                        continue
                    }
                }

                if ($payload.type -eq "in" -and $entryType -eq "overtime") {
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
                elseif ($payload.type -eq "in" -and $entryType -eq "diverse") {
                    $diverseReason = if ($payload.PSObject.Properties.Name -contains "diverseReason") { ([string]$payload.diverseReason).Trim() } else { "" }
                    if ([string]::IsNullOrWhiteSpace($diverseReason)) {
                        respondWithError $response 400 "A reason is required before starting diverse time."
                        continue
                    }
                }
                elseif ($payload.type -eq "out") {
                    if ($payload.PSObject.Properties.Name -contains "diverseSummary") {
                        $diverseSummary = ([string]$payload.diverseSummary).Trim()
                    }
                }

                $dataFile = Join-Path -Path $sharedFolder -ChildPath ("{0}_data.json" -f $employeeCode)
                if (!(Test-Path -Path $dataFile)) {
                    Write-JsonAtomic -Path $dataFile -Value @()
                }

                $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
                try {
                    $existingData = Read-JsonArrayFile -Path $dataFile
                    $activeEntry = Get-LatestActiveEntry -Entries $existingData

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
                            entryType    = $entryType
                            name        = Get-EmployeeName $employeeCode
                            date        = $todayText
                            punchIn     = $roundedNowText
                            exactPunchIn = $exactNowText
                            punchOut    = $null
                            exactPunchOut = $null
                            overtime    = $null
                            status      = "pending"
                            message     = ""
                            projectCode = if ($entryType -eq "overtime") { $projectCode } else { "" }
                            overtimeCode = if ($entryType -eq "overtime") { $overtimeCode } else { "" }
                            paymentOption = if ($entryType -eq "overtime") { $paymentOption } else { "" }
                            reasonCode = if ($entryType -eq "overtime") { $reasonCode } else { "" }
                            diverseReason = if ($entryType -eq "diverse") { $diverseReason } else { "" }
                            diverseSummary = ""
                        }
                    }
                    else {
                        if (-not $activeEntry) {
                            respondWithError $response 400 "No active punch-in record found."
                            continue
                        }

                        $activeEntryType = if ($activeEntry.PSObject.Properties.Name -contains "entryType" -and -not [string]::IsNullOrWhiteSpace([string]$activeEntry.entryType)) { ([string]$activeEntry.entryType).Trim().ToLowerInvariant() } else { "overtime" }

                        if ($activeEntryType -eq "diverse" -and [string]::IsNullOrWhiteSpace($diverseSummary)) {
                            respondWithError $response 400 "A work summary is required before ending diverse time."
                            continue
                        }

                        if ([string]$activeEntry.date -ne $todayText) {
                            if ($activeEntryType -eq "diverse") {
                                Set-EntryPropertyValue -Entry $activeEntry -Name "diverseSummary" -Value $diverseSummary
                            }
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
                            if ($activeEntryType -eq "diverse") {
                                Set-EntryPropertyValue -Entry $activeEntry -Name "diverseSummary" -Value $diverseSummary
                            }
                        }
                    }

                    Write-JsonAtomic -Path $dataFile -Value $existingData -Depth 6
                }
                finally {
                    Release-ResourceLock -LockHandle $lockHandle
                }

                Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null

                $result = [PSCustomObject]@{
                    message = $punchResultMessage
                    time    = $exactNowText
                    requiresClockOutReview = $requiresClockOutReview
                    reviewEntryDate = $reviewEntryDate
                    entryType = $entryType
                }
                respondWithSuccess $response ($result | ConvertTo-Json -Depth 6)
            }
            catch {
                respondWithError $response 500 "Unable to process punch: $($_.Exception.Message)"
            }
            continue
        }
