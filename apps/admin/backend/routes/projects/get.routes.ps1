        # GET /projects: Return the list of projects.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/projects/?$") {
            try {
                $projectsData = @(Get-ProjectsForCurrentUser -CurrentUser $currentUser)
                $jsonResult = ConvertTo-Json -InputObject $projectsData -Depth 6
                respondWithSuccess $response $jsonResult
            }
            catch {
                Write-Warning ("Unable to retrieve projects: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to retrieve projects."
            }
            continue
        }
