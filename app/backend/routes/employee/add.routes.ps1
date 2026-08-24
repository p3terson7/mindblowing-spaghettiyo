        # POST /employee/add/{employeeCode}: Add an entry for an employee.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employee/add/(\d+)$") {
            $employeeCode = $matches[1]

            if (Test-CurrentUserMatchesEmployeeCode -CurrentUser $currentUser -EmployeeCode $employeeCode) {
                respondWithError $response 403 "Administrators cannot add overtime entries to their own employee profile."
                continue
            }

            $targetEmployee = Get-EmployeeUserByCode -EmployeeCode $employeeCode
            if ($null -eq $targetEmployee -or
                -not (Test-EmployeeUserRecord -UserRecord $targetEmployee -EmployeeCode $employeeCode) -or
                [bool]$targetEmployee.disabled) {
                respondWithError $response 404 "Active employee not found."
                continue
            }

            $dataFile = Ensure-EmployeeDataFile -EmployeeCode $employeeCode
            $payload = Read-JsonRequestBody -Request $request

            # Require payload to include date, punchIn, and punchOut.
            if (-not ($payload.date -and $payload.punchIn -and $payload.punchOut)) {
                respondWithError $response 400 "Missing required fields: date, punchIn, and punchOut are required."
                continue
            }

            $normalizedDate = Convert-ToNormalizedDateText -DateText ([string]$payload.date)
            if ([string]::IsNullOrWhiteSpace($normalizedDate)) {
                respondWithError $response 400 "Date must use the yyyy-MM-dd format."
                continue
            }

            # Require payload to include projectCode.
            if (-not $payload.projectCode) {
                respondWithError $response 400 "Missing required field: projectCode is required."
                continue
            }

            if (-not $payload.overtimeCode) {
                $payload | Add-Member -NotePropertyName overtimeCode -NotePropertyValue "" -Force
            }

            if (-not $payload.paymentOption) {
                respondWithError $response 400 "Missing required field: paymentOption is required."
                continue
            }

            if (-not ($payload.PSObject.Properties.Name -contains "reasonCode")) {
                $payload | Add-Member -NotePropertyName reasonCode -NotePropertyValue "" -Force
            }

            $workComment = if ($payload.PSObject.Properties.Name -contains "workComment") { ([string]$payload.workComment).Trim() } else { "" }
            $managerMessage = if ($payload.PSObject.Properties.Name -contains "message") { ([string]$payload.message).Trim() } else { "" }
            if ($workComment.Length -gt 1000) {
                respondWithError $response 400 "Employee comments cannot exceed 1000 characters."
                continue
            }
            if ($managerMessage.Length -gt 1000) {
                respondWithError $response 400 "Supervisor notes cannot exceed 1000 characters."
                continue
            }

            # Validate that the provided projectCode exists in the projects list.
            $projects = Get-ActiveProjects
            $projectExists = $projects | Where-Object { $_.projectCode -eq $payload.projectCode }
            if (-not $projectExists) {
                respondWithError $response 400 "Invalid projectCode: $($payload.projectCode) does not exist."
                continue
            }

            if (-not (Test-CurrentUserCanModifyProjectCode -CurrentUser $currentUser -ProjectCode ([string]$payload.projectCode))) {
                respondWithError $response 403 "You can view this project, but only assigned project admins can modify entries for it."
                continue
            }

            $overtimeCodes = Get-OvertimeCodes
            if (-not (Test-OptionCode -Options $overtimeCodes -Code ([string]$payload.overtimeCode) -AllowBlank $true)) {
                respondWithError $response 400 "Invalid overtimeCode: $($payload.overtimeCode) does not exist."
                continue
            }

            $paymentOptions = Get-PaymentOptions
            if (-not (Test-OptionCode -Options $paymentOptions -Code ([string]$payload.paymentOption) -AllowBlank $false)) {
                respondWithError $response 400 "Invalid paymentOption: $($payload.paymentOption) does not exist."
                continue
            }

            $reasonCodes = Get-ReasonCodes
            if (-not (Test-OptionCode -Options $reasonCodes -Code ([string]$payload.reasonCode) -AllowBlank $true)) {
                respondWithError $response 400 "Invalid reasonCode: $($payload.reasonCode) does not exist."
                continue
            }

            $exactPunchIn = Convert-ToNormalizedTimeText -TimeText ([string]$payload.punchIn)
            $exactPunchOut = Convert-ToNormalizedTimeText -TimeText ([string]$payload.punchOut)
            if ([string]::IsNullOrWhiteSpace($exactPunchIn) -or [string]::IsNullOrWhiteSpace($exactPunchOut)) {
                respondWithError $response 400 "Punch In and Punch Out must use a valid time format."
                continue
            }

            $punchInRounded = Convert-ToNearestQuarterHourText -Date $normalizedDate -TimeText $exactPunchIn
            $punchOutRounded = Convert-ToNearestQuarterHourText -Date $normalizedDate -TimeText $exactPunchOut

            # Validate the real interval. Rounded display times can legitimately
            # be identical when a short entry earns no quarter-hour credit.
            $creditSummary = Get-QuarterHourCreditSummary -Date $normalizedDate -PunchIn $exactPunchIn -PunchOut $exactPunchOut
            if (-not [bool]$creditSummary.isValid) {
                respondWithError $response 400 "Punch Out must be after Punch In."
                continue
            }

            $entryMutationCommitted = $false
            $entryMutationError = $null
            $postCommitWarnings = New-Object System.Collections.ArrayList
            try {
                $projectReferenceLockHandle = Acquire-ProjectReferenceLock
                try {
                    # Revalidate from disk while holding the same guard used by
                    # project rename/delete. The earlier cached validation is
                    # only for fast feedback and cannot authorize the commit.
                    if (-not (Test-ActiveProjectCodeFromDisk -ProjectCode ([string]$payload.projectCode))) {
                        respondWithError $response 409 "The selected project is no longer active. Refresh and choose another project."
                        continue
                    }
                    if (-not (Test-CurrentUserCanModifyActiveProjectCodeFromDisk -CurrentUser $currentUser -ProjectCode ([string]$payload.projectCode))) {
                        respondWithError $response 403 "Your permission for the selected project changed. Refresh and try again."
                        continue
                    }

                    $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
                    try {
                        # Build the collection explicitly. PowerShell 5.1 can
                        # unwrap a one-item function result into a PSCustomObject;
                        # using += on that value raises the op_Addition error.
                        $updatedEntries = New-Object System.Collections.ArrayList
                        foreach ($existingEntry in @(Read-JsonArrayFile -Path $dataFile)) {
                            [void]$updatedEntries.Add($existingEntry)
                        }

                        # Create the entry before adding optional notes. This keeps
                        # legacy entry fields unchanged when the optional fields are blank.
                        $newEntry = [PSCustomObject]@{
                            entryId      = New-EntryIdentifier
                            name        = Get-EmployeeName $employeeCode
                            date        = $normalizedDate
                            punchIn     = $punchInRounded
                            exactPunchIn = $exactPunchIn
                            punchOut    = $punchOutRounded
                            exactPunchOut = $exactPunchOut
                            overtime    = [string]$creditSummary.creditedOvertime
                            overtimeCalculationRule = "quarter-10m-v1"
                            status      = "pending"
                            message     = ""
                            projectCode = $payload.projectCode
                            overtimeCode = $payload.overtimeCode
                            paymentOption = $payload.paymentOption
                            reasonCode = $payload.reasonCode
                        }
                        if (-not [string]::IsNullOrWhiteSpace($workComment)) {
                            Set-EntryPropertyValue -Entry $newEntry -Name "workComment" -Value $workComment
                        }
                        if (-not [string]::IsNullOrWhiteSpace($managerMessage)) {
                            Set-EntrySupervisorNote -Entry $newEntry -Note $managerMessage -CurrentUser $currentUser | Out-Null
                        }
                        [void]$updatedEntries.Add($newEntry)
                        Write-JsonArrayAtomic -Path $dataFile -Items @($updatedEntries.ToArray()) -Depth 6
                        $entryMutationCommitted = $true
                    }
                    finally {
                        Release-ResourceLock -LockHandle $lockHandle
                    }
                }
                finally {
                    Release-ResourceLock -LockHandle $projectReferenceLockHandle
                }

                $historyWarning = Invoke-PostCommitActionSafely -Description "Entry saved, but history logging failed" -Action {
                    $employeeName = Get-EmployeeName $employeeCode
                    $formattedDate = (Get-Date $normalizedDate).ToString("MMMM dd, yyyy")
                    $historyMessage = "Added an entry on $formattedDate, starting at <strong>$(Format-TimeForHistory $punchInRounded)</strong> and finishing at <strong>$(Format-TimeForHistory $punchOutRounded)</strong> for project <strong>$($payload.projectCode)</strong>, overtime code <strong>$($payload.overtimeCode)</strong>, payment <strong>$($payload.paymentOption)</strong>, and reason <strong>$($payload.reasonCode)</strong>."
                    logHistory "Add" $historyMessage $employeeName -PublishChange:$false
                }
                if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                    [void]$postCommitWarnings.Add($historyWarning)
                }
            }
            catch {
                $entryMutationError = $_
                throw
            }
            finally {
                if ($entryMutationCommitted) {
                    $syncWarning = Invoke-PostCommitActionSafely -Description "Entry saved, but cross-machine refresh publication failed" -Action {
                        Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
                    }
                    if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                        [void]$postCommitWarnings.Add($syncWarning)
                    }
                }
            }

            $responseMessage = [PSCustomObject]@{
                message = "Entry added successfully."
                time    = $exactPunchIn
                warnings = @($postCommitWarnings.ToArray())
            }
            respondWithSuccess $response ($responseMessage | ConvertTo-Json -Depth 3)
            continue
        }
