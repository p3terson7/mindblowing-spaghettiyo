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

                if ([string]::IsNullOrWhiteSpace($displayName)) {
                    respondWithError $response 400 "Employee name is required."
                    continue
                }

                $existingEmployee = Get-EmployeeDirectoryList | Where-Object { $_.code -eq $employeeCode } | Select-Object -First 1
                if ($null -eq $existingEmployee) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }

                $updateResult = Update-EmployeeDirectoryRecord -EmployeeCode $employeeCode -DisplayName $displayName -Role $role
                if (-not $updateResult.updated) {
                    respondWithError $response 500 "Unable to update employee."
                    continue
                }

                $historyMessage = "Updated the employee profile for <strong>$displayName</strong>."
                logHistory "Update" $historyMessage $displayName
                Publish-DataChange -Category "employee-directory" -Resource $employeeCode

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
