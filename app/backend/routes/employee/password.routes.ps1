        # POST /employee/password/{employeeCode}: Reset or create an employee account password.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employee/password/(\d+)$") {
            $response.Headers["Cache-Control"] = "no-store"
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $employeeCode = $matches[1]

            try {
                try {
                    $payload = Read-JsonRequestBody -Request $request
                }
                catch [System.FormatException] {
                    respondWithError $response 400 $_.Exception.Message
                    continue
                }
                catch [System.IO.InvalidDataException] {
                    respondWithError $response 413 "The request body is too large."
                    continue
                }
                catch [System.TimeoutException] {
                    respondWithError $response 408 "Timed out while reading the request body."
                    continue
                }

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
                    $failureStatus = if ($passwordUpdateResult.error) { 409 } else { 500 }
                    respondWithError $response $failureStatus $errorMessage
                    continue
                }

                $postCommitWarnings = New-Object System.Collections.ArrayList
                $revokeWarning = Invoke-PostCommitActionSafely -Description "Password saved, but existing sessions could not be revoked" -Action {
                    Revoke-SessionsForUsername -Username $employeeCode
                }
                if (-not [string]::IsNullOrWhiteSpace($revokeWarning)) {
                    [void]$postCommitWarnings.Add($revokeWarning)
                }

                $historyWarning = Invoke-PostCommitActionSafely -Description "Password saved, but history logging failed" -Action {
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

                    logHistory "Update" $historyMessage $employeeName -PublishChange:$false
                }
                if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                    [void]$postCommitWarnings.Add($historyWarning)
                }

                $publishWarning = Invoke-PostCommitActionSafely -Description "Password saved, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "auth" -Resource $employeeCode | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($publishWarning)) {
                    [void]$postCommitWarnings.Add($publishWarning)
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
                    warnings           = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to update employee password: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to update employee password."
            }
            continue
        }
