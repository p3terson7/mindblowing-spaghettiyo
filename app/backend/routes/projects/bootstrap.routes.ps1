        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/projects/bootstrap") {
            try {
                $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
                $startDate = $query["startDate"]
                $endDate = $query["endDate"]
                $projectCode = $query["projectCode"]
                $includeDetail = $true
                $includeDetailText = [string]$query["includeDetail"]
                if (-not [string]::IsNullOrWhiteSpace($includeDetailText) -and -not [bool]::TryParse($includeDetailText, [ref]$includeDetail)) {
                    throw (New-Object System.ArgumentException -ArgumentList "includeDetail must be true or false.")
                }
                $requestedScope = [string]$query["scope"]
                if ([string]::IsNullOrWhiteSpace($requestedScope)) {
                    $requestedScope = "all"
                }
                $scope = ConvertTo-ProjectArchiveScope -Scope $requestedScope
            }
            catch [System.ArgumentException] {
                respondWithError $response 400 $_.Exception.Message
                continue
            }

            try {
                $payload = Get-ProjectsBootstrapModel -StartDate $startDate -EndDate $endDate -SelectedProjectCode $projectCode -Scope $scope -IncludeDetail:$includeDetail -CurrentUser $currentUser
                respondWithSuccess $response ($payload | ConvertTo-Json -Depth 8)
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to build project data: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Unable to build project data."
            }
            continue
        }
