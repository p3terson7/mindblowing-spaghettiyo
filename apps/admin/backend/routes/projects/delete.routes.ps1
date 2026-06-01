        # DELETE /projects/{projectCode}: Archive an existing project.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/projects/([^/]+)$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $projectCode = $matches[1]

            $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
            try {
                $projects = Get-Projects
                $found = $false
                for ($i = 0; $i -lt $projects.Count; $i++) {
                    if ([string]$projects[$i].projectCode -eq [string]$projectCode) {
                        $projects[$i].archived = $true
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

            logHistory "Archive" "Archived the project <strong>$projectCode</strong>." ([string]$currentUser.displayName)
            Publish-DataChange -Category "project" -Resource $projectCode
            respondWithSuccess $response '{ "message": "Project archived successfully." }'
            continue
        }
