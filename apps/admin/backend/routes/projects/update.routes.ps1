        # PUT /projects/{projectCode}: Update an existing project.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/projects/([^/]+)$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $projectCode = $matches[1]
            $payload = Read-JsonRequestBody -Request $request
            
            # Validate that projectName is provided (projectCode in URL is the identifier).
            if (-not $payload.projectName) {
                respondWithError $response 400 "Missing required field: projectName is required for update."
                continue
            }

            $sector = if ($payload.PSObject.Properties.Name -contains "sector") { [string]$payload.sector } else { "" }
            $admins = if ($payload.PSObject.Properties.Name -contains "admins") { @(ConvertTo-CodeArray -Value $payload.admins) } else { @() }
            $backupAdmins = if ($payload.PSObject.Properties.Name -contains "backupAdmins") { @(ConvertTo-CodeArray -Value $payload.backupAdmins) } else { @() }
            $archivedWasProvided = ($payload.PSObject.Properties.Name -contains "archived")
            $archived = if ($archivedWasProvided) { Test-ProjectArchived -Project $payload } else { $false }

            $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
            try {
                $projects = Get-Projects

                $found = $false
                for ($i = 0; $i -lt $projects.Count; $i++) {
                    if ($projects[$i].projectCode -eq $projectCode) {
                        $projects[$i].projectName = [string]$payload.projectName
                        $projects[$i].sector = $sector
                        $projects[$i].admins = $admins
                        $projects[$i].backupAdmins = $backupAdmins
                        $projects[$i].archived = if ($archivedWasProvided) { $archived } else { Test-ProjectArchived -Project $projects[$i] }
                        $found = $true
                        break
                    }
                }

                if (-not $found) {
                    respondWithError $response 404 "Project with code $projectCode not found."
                    continue
                }

                Write-JsonAtomic -Path $projectsFile -Value $projects -Depth 6
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }

            logHistory "Update" "Updated the project <strong>$projectCode</strong>." ([string]$currentUser.displayName)
            Publish-DataChange -Category "project" -Resource $projectCode
            respondWithSuccess $response '{ "message": "Project updated successfully." }'
            continue
        }
