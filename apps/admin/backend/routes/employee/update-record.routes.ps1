        # PUT /employees/{employeeCode}: Update employee directory metadata.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/employees/(\d+)$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $employeeCode = $matches[1]

            $directoryMutationMayHaveCommitted = $false
            $directoryMutationError = $null
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

                try {
                    # This call writes the name mapping before the auth profile, so even a false result can follow a commit.
                    $directoryMutationMayHaveCommitted = $true
                    $updateResult = Update-EmployeeDirectoryRecord -EmployeeCode $employeeCode -DisplayName $displayName -Role $role -TimeEntryTypes $timeEntryTypes -Gc179Profile $gc179Profile
                    if (-not $updateResult.updated) {
                        $directoryMutationError = [InvalidOperationException]::new("Unable to update employee.")
                        respondWithError $response 500 "Unable to update employee."
                        continue
                    }

                    $historyMessage = "Updated the employee profile for <strong>$displayName</strong>."
                    logHistory "Update" $historyMessage $displayName
                }
                catch {
                    $directoryMutationError = $_
                    throw
                }
                finally {
                    if ($directoryMutationMayHaveCommitted) {
                        try {
                            Publish-DataChange -Category "employee-directory" -Resource $employeeCode | Out-Null
                        }
                        catch {
                            if ($null -eq $directoryMutationError) {
                                throw
                            }

                            Write-Warning "Unable to publish employee-directory cache invalidation after a failed update operation: $($_.Exception.Message)"
                        }
                    }
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message      = "Employee updated successfully."
                    employeeCode = $employeeCode
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                respondWithError $response 500 "Unable to update employee: $($_.Exception.Message)"
            }
            continue
        }
