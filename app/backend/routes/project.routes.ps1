# ---------------------- PROJECTS ENDPOINTS -----------------------
if ($request.Url.AbsolutePath -match "^/projects") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserManager -CurrentUser $currentUser)) {
        respondWithError $response 403 "Manager access is required."
        continue
    }

    $projectRouteScript = Resolve-ProjectRouteScript -Method ([string]$request.HttpMethod) -Path ([string]$request.Url.AbsolutePath)
    if (-not [string]::IsNullOrWhiteSpace($projectRouteScript)) {
        Invoke-CachedRouteScript -RelativePath $projectRouteScript
    }
}
