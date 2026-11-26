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
                $postCommitWarnings = New-Object System.Collections.ArrayList
                $compensationWarning = Invoke-PostCommitActionSafely -Description "Profile saved, but overtime estimates could not be refreshed" -Action {
                    Update-EmployeeApprovedCompensationSnapshots -EmployeeCode ([string]$currentUser.employeeCode) -DeferPublication | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($compensationWarning)) {
                    [void]$postCommitWarnings.Add($compensationWarning)
                }
                $syncWarning = Invoke-PostCommitActionSafely -Description "GC179 profile saved, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "employee-directory" -Resource ([string]$currentUser.employeeCode) | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                    [void]$postCommitWarnings.Add($syncWarning)
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message      = "GC179 profile updated successfully."
                    gc179Profile = $updatedProfile
                    warnings     = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 6)
            }
            catch [System.ArgumentException] {
                respondWithError $response 400 $_.Exception.Message
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to update GC179 profile: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to update GC179 profile."
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/self/work-schedule" -and $request.HttpMethod -eq "PUT") {
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
                if ($null -eq $payload -or
                    -not ($payload.PSObject.Properties.Name -contains "compressedWorkWeek") -or
                    -not ($payload.compressedWorkWeek -is [bool])) {
                    respondWithError $response 400 "compressedWorkWeek must be true or false."
                    continue
                }

                $employeeCode = [string]$currentUser.employeeCode
                if (-not (Set-EmployeeUserCompressedWorkWeek -EmployeeCode $employeeCode -CompressedWorkWeek ([bool]$payload.compressedWorkWeek))) {
                    respondWithError $response 500 "Unable to update work schedule."
                    continue
                }

                $updatedUser = Get-EmployeeUserByCode -EmployeeCode $employeeCode
                $updatedProfile = Get-Gc179ProfileFromUserRecord -UserRecord $updatedUser
                $postCommitWarnings = New-Object System.Collections.ArrayList
                $syncWarning = Invoke-PostCommitActionSafely -Description "Work schedule saved, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "auth" -Resource $employeeCode | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                    [void]$postCommitWarnings.Add($syncWarning)
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message            = "Work schedule updated successfully."
                    workSchedule       = if ([bool]$updatedProfile.compressedWorkWeek) { "compressed" } else { "regular" }
                    gc179Profile       = $updatedProfile
                    warnings           = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 6)
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to update work schedule: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to update work schedule."
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/self/entries/comment" -and $request.HttpMethod -eq "POST") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }
            $employeeCode = [string]$currentUser.employeeCode
            if ($employeeCode -notmatch '^\d+$') {
                respondWithError $response 403 "Employee access is required."
                continue
            }

            $payload = Read-JsonRequestBody -Request $request
            $entryId = ([string]$payload.entryId).Trim()
            $date = Convert-ToNormalizedDateText -DateText ([string]$payload.date)
            $punchIn = Convert-ToNormalizedTimeText -TimeText ([string]$payload.punchIn)
            $commentId = ([string]$payload.commentId).Trim().ToLowerInvariant()
            $text = if ($payload.text -is [string]) { $payload.text.Trim() } else { "" }
            if ($commentId -notmatch '^[a-f0-9]{32}$' -or -not $text -or $text.Length -gt 1000 -or
                (-not $entryId -and (-not $date -or -not $punchIn))) {
                respondWithError $response 400 "An entry and a comment of 1 to 1000 characters are required."
                continue
            }

            # The employee code always comes from the session, never the body.
            $dataFile = Join-Path -Path $sharedFolder -ChildPath ("${employeeCode}_data.json")
            $committed = $false
            $lock = Acquire-ResourceLock -ResourcePath $dataFile
            try {
                $entries = @(Read-JsonArrayFile -Path $dataFile)
                $index = if ($entryId) { Find-EntryIndex -Entries $entries -EntryId $entryId } else { Find-EntryIndex -Entries $entries -Date $date -PunchIn $punchIn }
                if ($index -lt 0) {
                    respondWithError $response 404 "Entry not found."
                    continue
                }
                $entry = $entries[$index]
                if (-not $entry.punchOut -and -not (Test-EntryForgottenClockOut -Entry $entry)) {
                    respondWithError $response 409 "Finish the entry before adding a comment."
                    continue
                }
                $additions = if ($entry.PSObject.Properties.Name -contains "employeeCommentAdditions" -and $null -ne $entry.employeeCommentAdditions) { @($entry.employeeCommentAdditions) }
                $existing = @($additions | Where-Object { $_.id -eq $commentId } | Select-Object -First 1)
                if ($existing.Count -gt 0) {
                    if ([string]$existing[0].text -cne $text) {
                        respondWithError $response 409 "This comment identifier was already used."
                        continue
                    }
                }
                else {
                    if (@($additions | Where-Object { $null -ne $_ }).Count -ge 25) {
                        respondWithError $response 409 "This entry has reached its comment limit."
                        continue
                    }
                    $addition = [PSCustomObject]@{ id = $commentId; text = $text; createdAtUtc = (Get-Date).ToUniversalTime().ToString("o") }
                    Set-EntryPropertyValue -Entry $entry -Name "employeeCommentAdditions" -Value @(@($additions | Where-Object { $null -ne $_ }) + $addition)
                    Write-JsonArrayAtomic -Path $dataFile -Items $entries -Depth 10
                    $committed = $true
                }
                $savedAdditions = @(Get-EntryEmployeeCommentAdditions $entry)
            }
            finally {
                Release-ResourceLock -LockHandle $lock
            }

            $warnings = @()
            if ($committed) {
                $warning = Invoke-PostCommitActionSafely -Description "Entry comment saved, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
                }
                if ($warning) { $warnings += $warning }
            }
            respondWithSuccess $response (([PSCustomObject]@{ employeeCommentAdditions = $savedAdditions; warnings = $warnings }) | ConvertTo-Json -Depth 5)
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
            if (-not (Test-SaphirFileExists -Path $dataFile)) {
                respondWithSuccess $response "[]"
                continue
            }

            $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile | ForEach-Object { Convert-ToNormalizedEntryObject -Entry $_ })
            $entriesJson = ConvertTo-Json -InputObject @($entries) -Depth 6
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
                Rethrow-HttpStatusException -Exception $_.Exception
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
                $workComment = ""
                $diverseReason = ""
                $diverseSummary = ""
                $workSchedule = "unconfirmed"

                if ($payload.type -eq "in") {
                    $latestEmployeeUser = Get-EmployeeUserByCode -EmployeeCode $employeeCode
                    $latestEmployeeProfile = Get-Gc179ProfileFromUserRecord -UserRecord $latestEmployeeUser
                    $workSchedule = if ([bool]$latestEmployeeProfile.compressedWorkWeek) { "compressed" } else { "regular" }
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
                    if ($payload.PSObject.Properties.Name -contains "workComment") {
                        $workComment = ([string]$payload.workComment).Trim()
                    }
                    if ($payload.PSObject.Properties.Name -contains "diverseSummary") {
                        $diverseSummary = ([string]$payload.diverseSummary).Trim()
                    }
                    if ($workComment.Length -gt 1000 -or $diverseSummary.Length -gt 1000) {
                        respondWithError $response 400 "Work comments cannot exceed 1000 characters."
                        continue
                    }
                }

                $dataFile = Ensure-EmployeeDataFile -EmployeeCode $employeeCode
                $projectReferenceLockHandle = $null
                $lockHandle = $null
                try {
                    if ($payload.type -eq "in" -and $entryType -eq "overtime") {
                        $projectReferenceLockHandle = Acquire-ProjectReferenceLock
                        if (-not (Test-ActiveProjectCodeFromDisk -ProjectCode $projectCode)) {
                            respondWithError $response 409 "The selected project is no longer active. Refresh and choose another project."
                            continue
                        }
                    }

                    $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
                    try {
                        $existingData = @(Read-JsonArrayFile -Path $dataFile)
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
                                workComment = ""
                                diverseReason = if ($entryType -eq "diverse") { $diverseReason } else { "" }
                                diverseSummary = ""
                                workSchedule = $workSchedule
                                workScheduleSource = "employee-profile"
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
                            if ($activeEntryType -ne "diverse" -and [string]::IsNullOrWhiteSpace($workComment)) {
                                respondWithError $response 400 "A work comment is required before ending overtime."
                                continue
                            }

                            if ([string]$activeEntry.date -ne $todayText) {
                                if ($activeEntryType -eq "diverse") {
                                    Set-EntryPropertyValue -Entry $activeEntry -Name "diverseSummary" -Value $diverseSummary
                                }
                                else {
                                    Set-EntryPropertyValue -Entry $activeEntry -Name "workComment" -Value $workComment
                                }
                                Set-EntryForgottenClockOutReview -Entry $activeEntry -AttemptDate $todayText -AttemptTime $exactNowText
                                $requiresClockOutReview = $true
                                $reviewEntryDate = [string]$activeEntry.date
                                $punchResultMessage = "Previous-day clock-out requires supervisor review."
                            }
                            else {
                                Set-EntryPropertyValue -Entry $activeEntry -Name "exactPunchOut" -Value $exactNowText
                                Set-EntryPropertyValue -Entry $activeEntry -Name "punchOut" -Value $roundedNowText
                                Update-EntryComputedOvertime -Entry $activeEntry
                                if ($activeEntryType -eq "diverse") {
                                    Set-EntryPropertyValue -Entry $activeEntry -Name "diverseSummary" -Value $diverseSummary
                                }
                                else {
                                    Set-EntryPropertyValue -Entry $activeEntry -Name "workComment" -Value $workComment
                                }
                            }
                        }

                        Write-JsonArrayAtomic -Path $dataFile -Items $existingData -Depth 6
                    }
                    finally {
                        Release-ResourceLock -LockHandle $lockHandle
                    }
                }
                finally {
                    Release-ResourceLock -LockHandle $projectReferenceLockHandle
                }

                $postCommitWarnings = New-Object System.Collections.ArrayList
                $syncWarning = Invoke-PostCommitActionSafely -Description "Punch saved, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                    [void]$postCommitWarnings.Add($syncWarning)
                }

                $result = [PSCustomObject]@{
                    message = $punchResultMessage
                    time    = $exactNowText
                    requiresClockOutReview = $requiresClockOutReview
                    reviewEntryDate = $reviewEntryDate
                    entryType = $entryType
                    warnings = @($postCommitWarnings.ToArray())
                }
                respondWithSuccess $response ($result | ConvertTo-Json -Depth 6)
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to process punch: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to process punch."
            }
            continue
        }
