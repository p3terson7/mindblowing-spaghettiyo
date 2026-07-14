        # DELETE /employees/{employeeCode}: Disable an employee directory record.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/employees/(\d+)$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $employeeCode = $matches[1]

            $directoryMutationMayHaveCommitted = $false
            $directoryMutationError = $null
            try {
                $existingEmployee = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $employeeCode
                if ($null -eq $existingEmployee) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }

                try {
                    try {
                        $removeResult = Remove-EmployeeDirectoryRecord -EmployeeCode $employeeCode
                    }
                    catch {
                        # Session revocation can fail after the auth record has already been disabled.
                        $directoryMutationMayHaveCommitted = $true
                        throw
                    }
                    if (-not $removeResult.updated) {
                        respondWithError $response 500 "Unable to remove employee."
                        continue
                    }

                    $directoryMutationMayHaveCommitted = $true
                    $historyMessage = "Removed employee access for <strong>$($existingEmployee.name)</strong>."
                    logHistory "Delete" $historyMessage $existingEmployee.name
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

                            Write-Warning "Unable to publish employee-directory cache invalidation after a failed delete operation: $($_.Exception.Message)"
                        }
                    }
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message      = "Employee removed successfully."
                    employeeCode = $employeeCode
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                respondWithError $response 500 "Unable to remove employee: $($_.Exception.Message)"
            }
            continue
        }
