        # GET /projects: Return the list of projects.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/projects/?$") {
            try {
                $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
                $scope = ConvertTo-ProjectArchiveScope -Scope ([string]$query["scope"])
            }
            catch [System.ArgumentException] {
                respondWithError $response 400 $_.Exception.Message
                continue
            }

            try {
                $projectsData = @(Get-ProjectsForCurrentUser -CurrentUser $currentUser -Scope $scope)
                $jsonResult = ConvertTo-Json -InputObject $projectsData -Depth 6
                respondWithSuccess $response $jsonResult
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to retrieve projects: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to retrieve projects."
            }
            continue
        }
