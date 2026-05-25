# ---------------------- PROJECTS ENDPOINTS -----------------------
$currentUser = Get-AuthenticatedUserFromRequest -Request $request
if ($request.Url.AbsolutePath -match "^/projects") {
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserRole -CurrentUser $currentUser -AllowedRoles @("admin"))) {
        respondWithError $response 403 "Admin access is required."
        continue
    }
}

Invoke-CachedRouteScript -RelativePath "routes/projects/get.routes.ps1"
Invoke-CachedRouteScript -RelativePath "routes/projects/bootstrap.routes.ps1"
Invoke-CachedRouteScript -RelativePath "routes/projects/add.routes.ps1"
Invoke-CachedRouteScript -RelativePath "routes/projects/update.routes.ps1"
Invoke-CachedRouteScript -RelativePath "routes/projects/delete.routes.ps1"
