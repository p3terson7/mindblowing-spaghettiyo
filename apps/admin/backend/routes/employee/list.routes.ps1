        # GET /employees/bootstrap: Return People view data in one response.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/employees/bootstrap") {
            $employees = @(Get-EmployeeDirectoryList -IncludeDisabled:$true -CurrentUser $currentUser)
            $scopedProjects = @(Get-ProjectsForCurrentUser -CurrentUser $currentUser)
            $payload = [PSCustomObject]@{
                employees = $employees
                projects  = $scopedProjects
                lookups   = [PSCustomObject]@{
                    projects       = $scopedProjects
                    overtimeCodes  = @(Get-OvertimeCodes)
                    paymentOptions = @(Get-PaymentOptions)
                    reasonCodes    = @(Get-ReasonCodes)
                    timeEntryTypes = @("overtime")
                }
            }

            respondWithSuccess $response ($payload | ConvertTo-Json -Depth 8)
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

            $employees = @(Get-EmployeeDirectoryList -IncludeDisabled:$includeDisabled -CurrentUser $currentUser)
            if ($scope -eq "archived") {
                $employees = @($employees | Where-Object { [bool]$_.archived })
            }
            elseif ($scope -ne "all") {
                $employees = @($employees | Where-Object { -not [bool]$_.archived })
            }

            respondWithSuccess $response ($employees | ConvertTo-Json -Depth 4)
            continue
        }
