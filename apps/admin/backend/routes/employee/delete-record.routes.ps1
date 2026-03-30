        # DELETE /employees/{employeeCode}: Disable an employee directory record.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/employees/(\d+)$") {
            $employeeCode = $matches[1]

            try {
                $existingEmployee = Get-EmployeeDirectoryList | Where-Object { $_.code -eq $employeeCode } | Select-Object -First 1
                if ($null -eq $existingEmployee) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }

                $removeResult = Remove-EmployeeDirectoryRecord -EmployeeCode $employeeCode
                if (-not $removeResult.updated) {
                    respondWithError $response 500 "Unable to remove employee."
                    continue
                }

                $historyMessage = "Removed employee access for <strong>$($existingEmployee.name)</strong>."
                logHistory "Delete" $historyMessage $existingEmployee.name
                Publish-DataChange -Category "employee-directory" -Resource $employeeCode

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
