        # POST /employees/{employeeCode}/restore: Re-enable an archived employee directory record.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employees/(\d+)/restore$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $employeeCode = $matches[1]

            try {
                $existingEmployee = Get-EmployeeDirectoryRecordMetadata -EmployeeCode $employeeCode -IncludeDisabled:$true
                if ($null -eq $existingEmployee) {
                    respondWithError $response 404 "Employee not found."
                    continue
                }

                # An already-active account can be a retry after its data-file
                # repair failed. Re-running restore is safe and lets the
                # secondary initialization complete without duplicate history.
                $wasAlreadyActive = -not [bool]$existingEmployee.archived
                $restoreResult = Restore-EmployeeDirectoryRecord -EmployeeCode $employeeCode
                if (-not $restoreResult.updated) {
                    respondWithError $response 500 "Unable to reinstate employee."
                    continue
                }

                $postCommitWarnings = New-Object System.Collections.ArrayList
                if ($restoreResult.PSObject.Properties.Name -contains "warnings") {
                    foreach ($warning in @($restoreResult.warnings)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
                            [void]$postCommitWarnings.Add([string]$warning)
                        }
                    }
                }

                if (-not $wasAlreadyActive) {
                    $historyMessage = "Reinstated employee access for <strong>$($existingEmployee.name)</strong>."
                    $historyWarning = Invoke-PostCommitActionSafely -Description "Employee access restored, but history logging failed" -Action {
                        logHistory "Update" $historyMessage $existingEmployee.name -PublishChange:$false
                    }
                    if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                        [void]$postCommitWarnings.Add($historyWarning)
                    }
                }

                $syncWarning = Invoke-PostCommitActionSafely -Description "Employee access restored, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "employee-directory" -Resource $employeeCode | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                    [void]$postCommitWarnings.Add($syncWarning)
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message       = if ($wasAlreadyActive) { "Employee access was already active; initialization was retried." } else { "Employee reinstated successfully." }
                    employeeCode  = $employeeCode
                    alreadyActive = $wasAlreadyActive
                    warnings      = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 6)
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to reinstate employee: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to reinstate employee."
            }
            continue
        }
