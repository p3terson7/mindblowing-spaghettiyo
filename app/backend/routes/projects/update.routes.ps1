        # PUT /projects/{projectCode}: Update an existing project.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/projects/([^/]+)$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $projectCode = [System.Uri]::UnescapeDataString([string]$matches[1]).Trim()
            $payload = Read-JsonRequestBody -Request $request
            if ($null -eq $payload) {
                respondWithError $response 400 "A project update payload is required."
                continue
            }

            $projectName = if ($payload.PSObject.Properties.Name -contains "projectName") { ([string]$payload.projectName).Trim() } else { "" }
            $requestedProjectCode = if ($payload.PSObject.Properties.Name -contains "projectCode") { ([string]$payload.projectCode).Trim() } else { $projectCode }
            $colorKeyWasProvided = ($payload.PSObject.Properties.Name -contains "colorKey")
            $requestedColorKey = if ($colorKeyWasProvided) { ([string]$payload.colorKey).Trim().ToLowerInvariant() } else { "" }
            $markerKeyWasProvided = ($payload.PSObject.Properties.Name -contains "markerKey")
            $requestedMarkerKey = if ($markerKeyWasProvided) { ([string]$payload.markerKey).Trim().ToLowerInvariant() } else { "" }
            $projectCodeChanged = ($requestedProjectCode -cne $projectCode)
            if ($projectName.Length -gt 200) {
                respondWithError $response 400 "Project name cannot exceed 200 characters."
                continue
            }
            if ($projectCodeChanged -and -not (Test-ProjectCodeFormat -ProjectCode $requestedProjectCode)) {
                respondWithError $response 400 "File number must be 1 to 64 characters and use letters, numbers, spaces, periods, underscores, or hyphens."
                continue
            }
            if ($colorKeyWasProvided -and -not [string]::IsNullOrWhiteSpace($requestedColorKey) -and -not (Test-ProjectColorKey -ColorKey $requestedColorKey)) {
                respondWithError $response 400 "Unsupported project color."
                continue
            }
            if ($markerKeyWasProvided -and -not [string]::IsNullOrWhiteSpace($requestedMarkerKey) -and -not (Test-ProjectMarkerKey -MarkerKey $requestedMarkerKey)) {
                respondWithError $response 400 "Unsupported project marker."
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
            $archivedWasProvided = ($payload.PSObject.Properties.Name -contains "archived")
            $archived = if ($archivedWasProvided) { Test-ProjectArchived -Project $payload } else { $false }

            $projectMutationCommitted = $false
            $projectMutationError = $null
            $postCommitWarnings = New-Object System.Collections.ArrayList
            try {
                $referenceLockHandle = Acquire-ProjectReferenceLock
                try {
                    $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
                    try {
                        $projects = @(Read-ProjectsFromDisk)
                        $projectIndex = -1
                        for ($i = 0; $i -lt $projects.Count; $i++) {
                            if ([string]$projects[$i].projectCode -eq $projectCode) {
                                $projectIndex = $i
                                break
                            }
                        }

                        if ($projectIndex -lt 0) {
                            respondWithError $response 404 "Project with code $projectCode not found."
                            continue
                        }

                        if ($projectCodeChanged) {
                            $duplicateProject = $false
                            for ($i = 0; $i -lt $projects.Count; $i++) {
                                if ($i -ne $projectIndex -and [string]$projects[$i].projectCode -eq $requestedProjectCode) {
                                    $duplicateProject = $true
                                    break
                                }
                            }
                            if ($duplicateProject) {
                                respondWithError $response 400 "Project with code $requestedProjectCode already exists."
                                continue
                            }

                            $referenceSummary = Get-ProjectEntryReferenceSummary -ProjectCode $projectCode
                            if ([int]$referenceSummary.referenceCount -gt 0) {
                                respondWithError $response 409 "File number cannot be changed because this project is used by $([int]$referenceSummary.referenceCount) overtime entries."
                                continue
                            }
                        }

                        $projects[$projectIndex].projectCode = $requestedProjectCode
                        $projects[$projectIndex].projectName = $projectName
                        $projects[$projectIndex].sector = $sector
                        $projects[$projectIndex].admins = $admins
                        $projects[$projectIndex].backupAdmins = $backupAdmins
                        $projects[$projectIndex].archived = if ($archivedWasProvided) { $archived } else { Test-ProjectArchived -Project $projects[$projectIndex] }
                        $existingColorKey = if ($projects[$projectIndex].PSObject.Properties.Name -contains "colorKey") { [string]$projects[$projectIndex].colorKey } else { "" }
                        [void](Set-ProjectRecordColorKey -Project $projects[$projectIndex] -ColorKey $(if ($colorKeyWasProvided) { $requestedColorKey } else { $existingColorKey }))
                        $existingMarkerKey = if ($projects[$projectIndex].PSObject.Properties.Name -contains "markerKey") { [string]$projects[$projectIndex].markerKey } else { "" }
                        [void](Set-ProjectRecordMarkerKey -Project $projects[$projectIndex] -MarkerKey $(if ($markerKeyWasProvided) { $requestedMarkerKey } else { $existingMarkerKey }))

                        Write-JsonArrayAtomic -Path $projectsFile -Items $projects -Depth 6
                        $script:ProjectsCache = $null
                        $projectMutationCommitted = $true
                    }
                    finally {
                        Release-ResourceLock -LockHandle $lockHandle
                    }
                }
                finally {
                    Release-ResourceLock -LockHandle $referenceLockHandle
                }

                $historyWarning = Invoke-PostCommitActionSafely -Description "Project update saved, but history logging failed" -Action {
                    $historyMessage = if ($projectCodeChanged) {
                        "Updated the project file number from <strong>$projectCode</strong> to <strong>$requestedProjectCode</strong>."
                    }
                    else {
                        "Updated the project <strong>$projectCode</strong>."
                    }
                    logHistory "Update" $historyMessage ([string]$currentUser.displayName) -PublishChange:$false
                }
                if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                    [void]$postCommitWarnings.Add($historyWarning)
                }
            }
            catch {
                $projectMutationError = $_
                throw
            }
            finally {
                if ($projectMutationCommitted) {
                    $cacheWarning = Invoke-PostCommitActionSafely -Description "Project update saved, but local cache invalidation failed" -Action {
                        Clear-LocalProjectMutationCaches
                    }
                    if (-not [string]::IsNullOrWhiteSpace($cacheWarning)) {
                        [void]$postCommitWarnings.Add($cacheWarning)
                    }
                    $syncWarning = Invoke-PostCommitActionSafely -Description "Project update saved, but cross-machine refresh publication failed" -Action {
                        Publish-DataChange -Category "project" -Resource $requestedProjectCode | Out-Null
                    }
                    if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                        [void]$postCommitWarnings.Add($syncWarning)
                    }
                }
            }

            respondWithSuccess $response (([PSCustomObject]@{
                message = "Project updated successfully."
                warnings = @($postCommitWarnings.ToArray())
            }) | ConvertTo-Json -Depth 4)
            continue
        }
