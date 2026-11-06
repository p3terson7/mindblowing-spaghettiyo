if ($request.Url.AbsolutePath -match "^/employees?") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserManager -CurrentUser $currentUser)) {
        respondWithError $response 403 "Manager access is required."
        continue
    }

    $employeeRouteScript = Resolve-EmployeeRouteScript -Method ([string]$request.HttpMethod) -Path ([string]$request.Url.AbsolutePath)
    if (-not [string]::IsNullOrWhiteSpace($employeeRouteScript)) {
        Invoke-CachedRouteScript -RelativePath $employeeRouteScript
    }
}
