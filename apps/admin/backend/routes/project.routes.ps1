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

. (Join-Path -Path $scriptDir -ChildPath "routes/projects/get.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/projects/add.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/projects/update.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/projects/delete.routes.ps1")
