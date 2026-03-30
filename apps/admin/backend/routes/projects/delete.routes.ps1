        # DELETE /projects/{projectCode}: Delete an existing project.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/projects/([^/]+)$") {
            $projectCode = $matches[1]

            $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
            try {
                $projectInUse = $false
                Get-ChildItem -Path $sharedFolder -Filter "*_data.json" | ForEach-Object {
                    if ($projectInUse) {
                        return
                    }

                    $entries = Read-JsonArrayFile -Path $_.FullName
                    if ($entries | Where-Object { [string]$_.projectCode -eq $projectCode }) {
                        $projectInUse = $true
                    }
                }

                if ($projectInUse) {
                    respondWithError $response 400 "This project is already used in overtime entries and cannot be removed."
                    continue
                }

                $projects = Get-Projects
                $originalCount = $projects.Count
                $projects = $projects | Where-Object { $_.projectCode -ne $projectCode }

                if ($projects.Count -eq $originalCount) {
                    respondWithError $response 404 "Project with code $projectCode not found."
                    continue
                }

                Write-JsonAtomic -Path $projectsFile -Value $projects -Depth 6
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }

            logHistory "Delete" "Removed the project <strong>$projectCode</strong>." ([string]$currentUser.displayName)
            Publish-DataChange -Category "project" -Resource $projectCode
            respondWithSuccess $response '{ "message": "Project deleted successfully." }'
            continue
        }
