        # PUT /projects/{projectCode}: Update an existing project.
        if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/projects/([^/]+)$") {
            $projectCode = $matches[1]
            $payload = Read-JsonRequestBody -Request $request
            
            # Validate that projectName is provided (projectCode in URL is the identifier).
            if (-not $payload.projectName) {
                respondWithError $response 400 "Missing required field: projectName is required for update."
                continue
            }

            $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
            try {
                $projects = Get-Projects

                $found = $false
                for ($i = 0; $i -lt $projects.Count; $i++) {
                    if ($projects[$i].projectCode -eq $projectCode) {
                        $projects[$i].projectName = [string]$payload.projectName
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
