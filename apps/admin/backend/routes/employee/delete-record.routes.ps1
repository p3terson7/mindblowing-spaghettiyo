        # DELETE /employees/{employeeCode}: Disable an employee directory record.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/employees/(\d+)$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $employeeCode = $matches[1]

            try {
                # Include archived records so retrying a delete can finish
                # session revocation after a previous secondary failure.
                $existingEmployee = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $employeeCode -IncludeDisabled:$true
                if ($null -eq $existingEmployee) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }
                $wasAlreadyArchived = [bool]$existingEmployee.archived

                $removeResult = Remove-EmployeeDirectoryRecord -EmployeeCode $employeeCode
                if (-not $removeResult.updated) {
                    respondWithError $response 500 "Unable to remove employee."
                    continue
                }

                $postCommitWarnings = New-Object System.Collections.ArrayList
                if ($removeResult.PSObject.Properties.Name -contains "warnings") {
                    foreach ($warning in @($removeResult.warnings)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
                            [void]$postCommitWarnings.Add([string]$warning)
                        }
                    }
                }

                if (-not $wasAlreadyArchived) {
                    $historyMessage = "Removed employee access for <strong>$($existingEmployee.name)</strong>."
                    $historyWarning = Invoke-PostCommitActionSafely -Description "Employee access disabled, but history logging failed" -Action {
                        logHistory "Delete" $historyMessage $existingEmployee.name -PublishChange:$false
                    }
                    if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                        [void]$postCommitWarnings.Add($historyWarning)
                    }
                }

                $syncWarning = Invoke-PostCommitActionSafely -Description "Employee access disabled, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "employee-directory" -Resource $employeeCode | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                    [void]$postCommitWarnings.Add($syncWarning)
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message         = if ($wasAlreadyArchived) { "Employee access was already removed; cleanup was retried." } else { "Employee removed successfully." }
                    employeeCode    = $employeeCode
                    alreadyArchived = $wasAlreadyArchived
                    warnings        = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 6)
            }
            catch {
                Write-Warning ("Unable to remove employee: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to remove employee."
            }
            continue
        }
