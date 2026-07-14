        # POST /employee/password/{employeeCode}: Reset or create an employee account password.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employee/password/(\d+)$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $employeeCode = $matches[1]

            $authMutationMayHaveCommitted = $false
            $authMutationError = $null
            try {
                $payload = Read-JsonRequestBody -Request $request
                $newPassword = if ($null -ne $payload) { [string]$payload.newPassword } else { "" }
                if ([string]::IsNullOrWhiteSpace($newPassword)) {
                    respondWithError $response 400 "A new password is required."
                    continue
                }

                $mustChangePassword = $true
                if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "mustChangePassword")) {
                    $mustChangePassword = [bool]$payload.mustChangePassword
                }

                $policyError = Test-NewPasswordPolicy -Password $newPassword
                if ($policyError) {
                    respondWithError $response 400 $policyError
                    continue
                }

                try {
                    try {
                        $passwordUpdateResult = Set-EmployeeUserPassword -EmployeeCode $employeeCode -NewPassword $newPassword -MustChangePassword $mustChangePassword
                    }
                    catch {
                        # Cache clearing can fail after the users file has already been committed.
                        $authMutationMayHaveCommitted = $true
                        throw
                    }
                    if (-not $passwordUpdateResult.updated) {
                        $errorMessage = if ($passwordUpdateResult.error) { [string]$passwordUpdateResult.error } else { "Unable to update employee password." }
                        respondWithError $response 500 $errorMessage
                        continue
                    }

                    $authMutationMayHaveCommitted = $true
                    Revoke-SessionsForUsername -Username $employeeCode

                    $employeeName = [string](Get-EmployeeName $employeeCode)
                    $historyMessage = if ($passwordUpdateResult.created) {
                        "Created a sign-in account and set a password for <strong>$employeeName</strong>."
                    }
                    elseif ($mustChangePassword) {
                        "Reset the password for <strong>$employeeName</strong> and required a password change at next sign-in."
                    }
                    else {
                        "Reset the password for <strong>$employeeName</strong>."
                    }

                    logHistory "Update" $historyMessage $employeeName
                }
                catch {
                    $authMutationError = $_
                    throw
                }
                finally {
                    if ($authMutationMayHaveCommitted) {
                        try {
                            Publish-DataChange -Category "auth" -Resource $employeeCode | Out-Null
                        }
                        catch {
                            if ($null -eq $authMutationError) {
                                throw
                            }

                            Write-Warning "Unable to publish auth cache invalidation after a failed password operation: $($_.Exception.Message)"
                        }
                    }
                }

                $message = if ($mustChangePassword) {
                    "Password updated successfully. The employee will need to change it on the next sign-in."
                }
                else {
                    "Password updated successfully."
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message            = $message
                    employeeCode       = $employeeCode
                    mustChangePassword = $mustChangePassword
                    createdAccount     = [bool]$passwordUpdateResult.created
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                respondWithError $response 500 "Unable to update employee password: $($_.Exception.Message)"
            }
            continue
        }
