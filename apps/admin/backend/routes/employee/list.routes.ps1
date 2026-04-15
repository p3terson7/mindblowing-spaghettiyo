        # GET /employees: Return employee list
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/employees") {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $scope = [string]$query["scope"]
            $includeDisabled = $false

            if ($scope -eq "all" -or $scope -eq "archived") {
                $includeDisabled = $true
            }

            $employees = @(Get-EmployeeDirectoryList -IncludeDisabled:$includeDisabled)
            if ($scope -eq "archived") {
                $employees = @($employees | Where-Object { [bool]$_.archived })
            }
            elseif ($scope -ne "all") {
                $employees = @($employees | Where-Object { -not [bool]$_.archived })
            }

            respondWithSuccess $response ($employees | ConvertTo-Json -Depth 4)
            continue
        }
