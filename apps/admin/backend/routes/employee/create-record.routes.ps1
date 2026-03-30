        # POST /employees: Create a new employee directory record and sign-in account.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/employees") {
            try {
                $payload = Read-JsonRequestBody -Request $request
                $employeeCode = if ($null -ne $payload) { [string]$payload.code } else { "" }
                $displayName = if ($null -ne $payload) { [string]$payload.name } else { "" }
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

                $existingEmployee = Get-EmployeeDirectoryList | Where-Object { $_.code -eq $employeeCode } | Select-Object -First 1
                if ($null -ne $existingEmployee) {
                    respondWithError $response 400 "An active employee already exists for this code."
                    continue
                }

                $createResult = Add-EmployeeDirectoryRecord -EmployeeCode $employeeCode -DisplayName $displayName -InitialPassword $initialPassword -MustChangePassword $mustChangePassword
                if (-not $createResult.updated) {
                    $errorMessage = if ($createResult.error) { [string]$createResult.error } else { "Unable to create employee." }
                    respondWithError $response 400 $errorMessage
                    continue
                }

                $historyMessage = "Created an employee profile for <strong>$displayName</strong> with code <strong>$employeeCode</strong>."
                logHistory "Add" $historyMessage $displayName
                Publish-DataChange -Category "employee-directory" -Resource $employeeCode

                respondWithSuccess $response (([PSCustomObject]@{
                    message            = "Employee created successfully."
                    employeeCode       = $employeeCode
                    temporaryPassword  = [string]$createResult.temporaryPassword
                    mustChangePassword = $mustChangePassword
                    createdAccount     = [bool]$createResult.created
                    reactivatedAccount = [bool]$createResult.reactivated
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                respondWithError $response 500 "Unable to create employee: $($_.Exception.Message)"
            }
            continue
        }
