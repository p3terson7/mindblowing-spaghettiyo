$currentUser = Get-AuthenticatedUserFromRequest -Request $request
if ($request.Url.AbsolutePath -match "^/stats/") {
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserRole -CurrentUser $currentUser -AllowedRoles @("admin"))) {
        respondWithError $response 403 "Admin access is required."
        continue
    }
}

Invoke-CachedRouteScript -RelativePath "routes/stats/summary.routes.ps1"
Invoke-CachedRouteScript -RelativePath "routes/stats/trends.routes.ps1"
Invoke-CachedRouteScript -RelativePath "routes/stats/detail.routes.ps1"
