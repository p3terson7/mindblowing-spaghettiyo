        # POST /projects: Create a new project.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/projects") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $payload = Read-JsonRequestBody -Request $request
            
            # Validate that projectCode and projectName are provided.
            if (-not ($payload.projectCode -and $payload.projectName)) {
                respondWithError $response 400 "Missing required fields: projectCode and projectName are required."
                continue
            }

            $sector = if ($payload.PSObject.Properties.Name -contains "sector") { [string]$payload.sector } else { "" }
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
                    $projects = Get-Projects

                    # Check for duplicate projectCode.
                    if ($projects | Where-Object { $_.projectCode -eq $payload.projectCode }) {
                        respondWithError $response 400 "Project with code $($payload.projectCode) already exists."
                        continue
                    }

                    # Append the new project.
                    $projects += [PSCustomObject]@{
                        projectCode  = [string]$payload.projectCode
                        projectName  = [string]$payload.projectName
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

                logHistory "Add" "Created a project named <strong>$([string]$payload.projectName)</strong> with code <strong>$([string]$payload.projectCode)</strong>." ([string]$currentUser.displayName)
            }
            catch {
                $projectMutationError = $_
                throw
            }
            finally {
                if ($projectMutationCommitted) {
                    try {
                        Publish-DataChange -Category "project" -Resource ([string]$payload.projectCode) | Out-Null
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
