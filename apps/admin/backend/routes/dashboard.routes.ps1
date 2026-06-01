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
        respondWithSuccess $response ($payload | ConvertTo-Json -Depth 8)
    }
    catch {
        respondWithError $response 500 "Unable to build dashboard data: $($_.Exception.Message)"
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
        respondWithSuccess $response ($payload | ConvertTo-Json -Depth 8)
    }
    catch {
        respondWithError $response 500 "Unable to build approvals data: $($_.Exception.Message)"
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
        $payload = [PSCustomObject]@{
            approvals = @(Get-ApprovalsEntriesModel -CurrentUser $currentUser)
            history   = @(Get-HistoryEntriesSnapshot)
        }
        respondWithSuccess $response ($payload | ConvertTo-Json -Depth 8)
    }
    catch {
        respondWithError $response 500 "Unable to build review data: $($_.Exception.Message)"
    }
    continue
}
