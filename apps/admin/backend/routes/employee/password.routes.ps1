        # POST /employee/password/{employeeCode}: Reset or create an employee account password.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employee/password/(\d+)$") {
            $employeeCode = $matches[1]

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

                $passwordUpdateResult = Set-EmployeeUserPassword -EmployeeCode $employeeCode -NewPassword $newPassword -MustChangePassword $mustChangePassword
                if (-not $passwordUpdateResult.updated) {
                    $errorMessage = if ($passwordUpdateResult.error) { [string]$passwordUpdateResult.error } else { "Unable to update employee password." }
                    respondWithError $response 500 $errorMessage
                    continue
                }

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
                Publish-DataChange -Category "auth" -Resource $employeeCode

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
