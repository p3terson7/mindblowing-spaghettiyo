if ($request.Url.AbsolutePath -match "^/employees?") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserRole -CurrentUser $currentUser -AllowedRoles @("admin"))) {
        respondWithError $response 403 "Admin access is required."
        continue
    }

    Invoke-CachedRouteScript -RelativePath "routes/employee/list.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/create-record.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/update-record.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/delete-record.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/restore-record.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/password.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/get.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/add.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/update.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/batch-approval.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/approval.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/message.routes.ps1"
    Invoke-CachedRouteScript -RelativePath "routes/employee/delete.routes.ps1"
}
