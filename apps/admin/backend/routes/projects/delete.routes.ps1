        # DELETE /projects/{projectCode}: Delete an existing project.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/projects/([^/]+)$") {
            $projectCode = $matches[1]

            $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
            try {
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

            Publish-DataChange -Category "project" -Resource $projectCode
            respondWithSuccess $response '{ "message": "Project deleted successfully." }'
            continue
        }
