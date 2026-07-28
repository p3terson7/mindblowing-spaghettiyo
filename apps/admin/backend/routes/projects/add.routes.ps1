        # POST /projects: Create a new project.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/projects") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $payload = Read-JsonRequestBody -Request $request
            
            $projectCode = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "projectCode") { ([string]$payload.projectCode).Trim() } else { "" }
            $projectName = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "projectName") { ([string]$payload.projectName).Trim() } else { "" }

            if ([string]::IsNullOrWhiteSpace($projectCode)) {
                respondWithError $response 400 "Missing required field: projectCode is required."
                continue
            }
            if (-not (Test-ProjectCodeFormat -ProjectCode $projectCode)) {
                respondWithError $response 400 "File number must be 1 to 64 characters and use letters, numbers, spaces, periods, underscores, or hyphens."
                continue
            }
            if ($projectName.Length -gt 200) {
                respondWithError $response 400 "Project name cannot exceed 200 characters."
                continue
            }

            $sector = if ($payload.PSObject.Properties.Name -contains "sector") { ([string]$payload.sector).Trim() } else { "" }
            $admins = if ($payload.PSObject.Properties.Name -contains "admins") { @(ConvertTo-CodeArray -Value $payload.admins) } else { @() }
            $backupAdmins = if ($payload.PSObject.Properties.Name -contains "backupAdmins") { @(ConvertTo-CodeArray -Value $payload.backupAdmins) } else { @() }
            $invalidAdminCode = ""
            foreach ($adminCode in @($admins + $backupAdmins)) {
                if (-not (Test-EmployeeCodeHasAdminRole -EmployeeCode ([string]$adminCode))) {
                    $invalidAdminCode = [string]$adminCode
                    break
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($invalidAdminCode)) {
                respondWithError $response 400 "Project admins and backup admins must be admin users. $invalidAdminCode is not an admin."
                continue
            }

            $projectMutationCommitted = $false
            $projectMutationError = $null
            try {
                $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
                try {
                    $projects = @(Get-Projects)

                    # Check for duplicate projectCode.
                    if ($projects | Where-Object { [string]$_.projectCode -ieq $projectCode }) {
                        respondWithError $response 400 "Project with code $projectCode already exists."
                        continue
                    }

                    # Append the new project.
                    $projects += [PSCustomObject]@{
                        projectCode  = $projectCode
                        projectName  = $projectName
                        sector       = $sector
                        admins       = $admins
                        backupAdmins = $backupAdmins
                        archived     = $false
                    }
                    Write-JsonAtomic -Path $projectsFile -Value $projects -Depth 6
                    $projectMutationCommitted = $true
                }
                finally {
                    Release-ResourceLock -LockHandle $lockHandle
                }

                $historyMessage = if ([string]::IsNullOrWhiteSpace($projectName)) {
                    "Created a project with code <strong>$projectCode</strong>."
                }
                else {
                    "Created a project named <strong>$projectName</strong> with code <strong>$projectCode</strong>."
                }
                logHistory "Add" $historyMessage ([string]$currentUser.displayName)
            }
            catch {
                $projectMutationError = $_
                throw
            }
            finally {
                if ($projectMutationCommitted) {
                    try {
                        Publish-DataChange -Category "project" -Resource $projectCode | Out-Null
                    }
                    catch {
                        if ($null -eq $projectMutationError) {
                            throw
                        }

                        Write-Warning "Unable to publish project cache invalidation after a failed add operation: $($_.Exception.Message)"
                    }
                }
            }

            respondWithSuccess $response '{ "message": "Project added successfully." }'
            continue
        }
