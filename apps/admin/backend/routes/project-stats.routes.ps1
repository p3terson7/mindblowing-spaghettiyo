if ($request.Url.AbsolutePath -match "^/stats/") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserManager -CurrentUser $currentUser)) {
        respondWithError $response 403 "Manager access is required."
        continue
    }

    Invoke-CachedRouteScript -RelativePath "routes/stats/summary.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/stats/trends.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/stats/detail.routes.ps1"
}
