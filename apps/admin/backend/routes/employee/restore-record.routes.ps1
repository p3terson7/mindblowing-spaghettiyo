        # POST /employees/{employeeCode}/restore: Re-enable an archived employee directory record.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employees/(\d+)/restore$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $employeeCode = $matches[1]

            $directoryMutationMayHaveCommitted = $false
            $directoryMutationError = $null
            try {
                $existingEmployee = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $employeeCode -IncludeDisabled:$true
                if ($null -eq $existingEmployee) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }

                if (-not [bool]$existingEmployee.archived) {
                    respondWithError $response 400 "Employee is already active."
                    continue
                }

                try {
                    try {
                        $restoreResult = Restore-EmployeeDirectoryRecord -EmployeeCode $employeeCode
                    }
                    catch {
                        # Entry-file initialization can fail after the auth record has already been restored.
                        $directoryMutationMayHaveCommitted = $true
                        throw
                    }
                    if (-not $restoreResult.updated) {
                        respondWithError $response 500 "Unable to reinstate employee."
                        continue
                    }

                    $directoryMutationMayHaveCommitted = $true
                    $historyMessage = "Reinstated employee access for <strong>$($existingEmployee.name)</strong>."
                    logHistory "Update" $historyMessage $existingEmployee.name
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

                            Write-Warning "Unable to publish employee-directory cache invalidation after a failed restore operation: $($_.Exception.Message)"
                        }
                    }
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message      = "Employee reinstated successfully."
                    employeeCode = $employeeCode
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                respondWithError $response 500 "Unable to reinstate employee: $($_.Exception.Message)"
            }
            continue
        }
