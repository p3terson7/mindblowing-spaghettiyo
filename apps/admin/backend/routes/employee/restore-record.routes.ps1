        # POST /employees/{employeeCode}/restore: Re-enable an archived employee directory record.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employees/(\d+)/restore$") {
            $employeeCode = $matches[1]

            try {
                $existingEmployee = Get-EmployeeDirectoryList -IncludeDisabled:$true | Where-Object { $_.code -eq $employeeCode } | Select-Object -First 1
                if ($null -eq $existingEmployee) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }

                if (-not [bool]$existingEmployee.archived) {
                    respondWithError $response 400 "Employee is already active."
                    continue
                }

                $restoreResult = Restore-EmployeeDirectoryRecord -EmployeeCode $employeeCode
                if (-not $restoreResult.updated) {
                    respondWithError $response 500 "Unable to reinstate employee."
                    continue
                }

                $historyMessage = "Reinstated employee access for <strong>$($existingEmployee.name)</strong>."
                logHistory "Update" $historyMessage $existingEmployee.name
                Publish-DataChange -Category "employee-directory" -Resource $employeeCode

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
