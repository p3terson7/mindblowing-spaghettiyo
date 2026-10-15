        # GET /employees/bootstrap: Return People view data in one response.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/employees/bootstrap") {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $scope = if ($query["scope"]) { [string]$query["scope"] } else { "active" }
            if ($scope -notin @("active", "archived", "all")) { respondWithError $response 400 "Invalid employee scope."; continue }
            $employees = @(Get-EmployeeDirectoryList -IncludeDisabled:($scope -ne "active") -CurrentUser $currentUser -MetadataOnly:($query["includeStats"] -ne "true") -Scope $scope)
            # Include archived references for historical entries; mutation
            # controls filter them out before offering a new assignment.
            $scopedProjects = @(Get-ProjectsForCurrentUser -CurrentUser $currentUser -Scope "all")
            $payload = [PSCustomObject]@{
                employees = $employees
                projects  = $scopedProjects
            }

            $json = if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Http.SerializePersonnel" -Component "Http" -Type "json" -Action { $payload | ConvertTo-Json -Depth 8 } } else { $payload | ConvertTo-Json -Depth 8 }
            respondWithSuccess $response $json
            continue
        }

        # GET /employees: Return employee list
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/employees") {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $scope = [string]$query["scope"]
            $includeDisabled = $false

            if ($scope -eq "all" -or $scope -eq "archived") {
                $includeDisabled = $true
            }

            $directoryScope = if ($scope -in @("all", "archived")) { $scope } else { "active" }
            $employees = @(Get-EmployeeDirectoryList -IncludeDisabled:$includeDisabled -CurrentUser $currentUser -Scope $directoryScope)
            if ($scope -eq "archived") {
                $employees = @($employees | Where-Object { [bool]$_.archived })
            }
            elseif ($scope -ne "all") {
                $employees = @($employees | Where-Object { -not [bool]$_.archived })
            }

            respondWithSuccess $response (ConvertTo-Json -InputObject @($employees) -Depth 8)
            continue
        }
