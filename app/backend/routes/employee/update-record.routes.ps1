        # PUT /employees/{employeeCode}: Update employee directory metadata.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/employees/(\d+)$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $employeeCode = $matches[1]

            try {
                $payload = Read-JsonRequestBody -Request $request
                $displayName = if ($null -ne $payload) { [string]$payload.name } else { "" }
                $role = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "role")) { Get-NormalizedRoleName -Role ([string]$payload.role) } else { "" }
                $timeEntryTypes = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "timeEntryTypes")) { @(ConvertTo-TimeEntryTypeArray -Value $payload.timeEntryTypes) } else { $null }
                $gc179Profile = if ($null -ne $payload -and ($payload.PSObject.Properties.Name -contains "gc179Profile")) { $payload.gc179Profile } else { $null }

                if ([string]::IsNullOrWhiteSpace($displayName)) {
                    respondWithError $response 400 "Employee name is required."
                    continue
                }

                $existingEmployee = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $employeeCode
                if ($null -eq $existingEmployee) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }

                $updateResult = Update-EmployeeDirectoryRecord -EmployeeCode $employeeCode -DisplayName $displayName -Role $role -TimeEntryTypes $timeEntryTypes -Gc179Profile $gc179Profile
                if (-not $updateResult.updated) {
                    $errorMessage = if ($updateResult.error) { [string]$updateResult.error } else { "Unable to update employee." }
                    respondWithError $response 500 $errorMessage
                    continue
                }

                $postCommitWarnings = New-Object System.Collections.ArrayList
                if ($updateResult.PSObject.Properties.Name -contains "warnings") {
                    foreach ($warning in @($updateResult.warnings)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
                            [void]$postCommitWarnings.Add([string]$warning)
                        }
                    }
                }

                $historyMessage = "Updated the employee profile for <strong>$displayName</strong>."
                $historyWarning = Invoke-PostCommitActionSafely -Description "Employee profile saved, but history logging failed" -Action {
                    logHistory "Update" $historyMessage $displayName -PublishChange:$false
                }
                if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                    [void]$postCommitWarnings.Add($historyWarning)
                }

                $syncWarning = Invoke-PostCommitActionSafely -Description "Employee profile saved, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "employee-directory" -Resource $employeeCode | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                    [void]$postCommitWarnings.Add($syncWarning)
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message      = "Employee updated successfully."
                    employeeCode = $employeeCode
                    warnings     = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 6)
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to update employee: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to update employee."
            }
            continue
        }
