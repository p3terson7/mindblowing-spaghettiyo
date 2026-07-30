        # POST /employees: Create a new employee directory record and sign-in account.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/employees") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            try {
                $payload = Read-JsonRequestBody -Request $request
                $employeeCode = if ($null -ne $payload) { [string]$payload.code } else { "" }
                $displayName = if ($null -ne $payload) { [string]$payload.name } else { "" }
                $role = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "role")) { Get-NormalizedRoleName -Role ([string]$payload.role) } else { "employee" }
                $timeEntryTypes = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "timeEntryTypes")) { @(ConvertTo-TimeEntryTypeArray -Value $payload.timeEntryTypes) } else { @("overtime") }
                $gc179Profile = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "gc179Profile")) { $payload.gc179Profile } else { $null }
                $initialPassword = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "initialPassword")) { [string]$payload.initialPassword } else { "" }
                $mustChangePassword = $true
                if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "mustChangePassword")) {
                    $mustChangePassword = [bool]$payload.mustChangePassword
                }

                if ([string]::IsNullOrWhiteSpace($employeeCode) -or [string]::IsNullOrWhiteSpace($displayName)) {
                    respondWithError $response 400 "Employee code and name are required."
                    continue
                }

                if ($employeeCode -notmatch "^\d+$") {
                    respondWithError $response 400 "Employee code must contain digits only."
                    continue
                }

                $existingEmployee = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $employeeCode
                if ($null -ne $existingEmployee) {
                    respondWithError $response 400 "An active employee already exists for this code."
                    continue
                }

                $createResult = Add-EmployeeDirectoryRecord -EmployeeCode $employeeCode -DisplayName $displayName -InitialPassword $initialPassword -MustChangePassword $mustChangePassword -Role $role -TimeEntryTypes $timeEntryTypes -Gc179Profile $gc179Profile
                if (-not $createResult.updated) {
                    $errorMessage = if ($createResult.error) { [string]$createResult.error } else { "Unable to create employee." }
                    respondWithError $response 400 $errorMessage
                    continue
                }

                $postCommitWarnings = New-Object System.Collections.ArrayList
                if ($createResult.PSObject.Properties.Name -contains "warnings") {
                    foreach ($warning in @($createResult.warnings)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
                            [void]$postCommitWarnings.Add([string]$warning)
                        }
                    }
                }

                $historyMessage = "Created an employee profile for <strong>$displayName</strong> with code <strong>$employeeCode</strong>."
                $historyWarning = Invoke-PostCommitActionSafely -Description "Employee created, but history logging failed" -Action {
                    logHistory "Add" $historyMessage $displayName -PublishChange:$false
                }
                if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                    [void]$postCommitWarnings.Add($historyWarning)
                }

                $syncWarning = Invoke-PostCommitActionSafely -Description "Employee created, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "employee-directory" -Resource $employeeCode | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                    [void]$postCommitWarnings.Add($syncWarning)
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message            = "Employee created successfully."
                    employeeCode       = $employeeCode
                    temporaryPassword  = [string]$createResult.temporaryPassword
                    mustChangePassword = $mustChangePassword
                    createdAccount     = [bool]$createResult.created
                    reactivatedAccount = [bool]$createResult.reactivated
                    warnings           = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 6)
            }
            catch {
                Write-Warning ("Unable to create employee: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to create employee."
            }
            continue
        }
