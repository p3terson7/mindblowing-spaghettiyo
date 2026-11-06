if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/dashboard/bootstrap") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }

    if (-not (Test-CurrentUserManager -CurrentUser $currentUser)) {
        respondWithError $response 403 "Manager access is required."
        continue
    }

    try {
        $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
        $employeeCode = $query["employeeCode"]
        $payload = Get-DashboardBootstrapModel -SelectedEmployeeCode $employeeCode -CurrentUser $currentUser
        $json = if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Http.SerializeDashboard" -Component "Http" -Type "json" -Action { $payload | ConvertTo-Json -Depth 8 } } else { $payload | ConvertTo-Json -Depth 8 }
        respondWithSuccess $response $json
    }
    catch {
        Rethrow-HttpStatusException -Exception $_.Exception
        Write-Warning ("Unable to build dashboard data: {0}" -f $_.Exception.Message)
        respondWithError $response 500 "Unable to build dashboard data."
    }
    continue
}

if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/approvals/entries") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }

    if (-not (Test-CurrentUserManager -CurrentUser $currentUser)) {
        respondWithError $response 403 "Manager access is required."
        continue
    }

    try {
        $payload = @(Get-ApprovalsEntriesModel -CurrentUser $currentUser)
        respondWithSuccess $response (ConvertTo-Json -InputObject $payload -Depth 8)
    }
    catch {
        Rethrow-HttpStatusException -Exception $_.Exception
        Write-Warning ("Unable to build approvals data: {0}" -f $_.Exception.Message)
        respondWithError $response 500 "Unable to build approvals data."
    }
    continue
}

if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/review/bootstrap") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }

    if (-not (Test-CurrentUserManager -CurrentUser $currentUser)) {
        respondWithError $response 403 "Manager access is required."
        continue
    }

    try {
        $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
        $page = 1
        if ($null -ne $query['page'] -and -not [int]::TryParse($query['page'], [ref]$page)) { throw [ArgumentException]::new('Invalid review page.') }
        $tab = if ($query['tab']) { $query['tab'] } else { 'pending' }
        $range = if ($query['range']) { $query['range'] } else { 'default' }
        $payload = Get-ReviewPage -CurrentUser $currentUser -Tab $tab -Page $page -Range $range -Search ([string]$query['search']) -EmployeeCode ([string]$query['employeeCode']) -ProjectCode ([string]$query['projectCode']) -StartDate ([string]$query['startDate']) -EndDate ([string]$query['endDate']) -SelectionOnly:($query['selectionOnly'] -eq 'true')
        $json = if ($script:SaphirPerformanceEnabled) { Invoke-SaphirDiagnosticCall -Name "Http.SerializeReview" -Component "Http" -Type "json" -Action { $payload | ConvertTo-Json -Depth 8 } } else { $payload | ConvertTo-Json -Depth 8 }
        respondWithSuccess $response $json
    }
    catch [ArgumentException] { respondWithError $response 400 $_.Exception.Message }
    catch {
        Rethrow-HttpStatusException -Exception $_.Exception
        Write-Warning ("Unable to build review data: {0}" -f $_.Exception.Message)
        respondWithError $response 500 "Unable to build review data."
    }
    continue
}
