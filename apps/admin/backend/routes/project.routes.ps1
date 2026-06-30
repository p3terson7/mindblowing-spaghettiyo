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

    Invoke-CachedRouteScript -RelativePath "routes/projects/get.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/projects/bootstrap.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/projects/add.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/projects/update.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/projects/delete.routes.ps1"
}
