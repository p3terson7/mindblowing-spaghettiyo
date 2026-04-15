$currentUser = Get-AuthenticatedUserFromRequest -Request $request
if ($null -eq $currentUser) {
    respondWithError $response 401 "Authentication required."
    continue
}
if (-not (Test-CurrentUserRole -CurrentUser $currentUser -AllowedRoles @("admin"))) {
    respondWithError $response 403 "Admin access is required."
    continue
}

. (Join-Path -Path $scriptDir -ChildPath "routes/employee/list.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/create-record.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/update-record.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/delete-record.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/restore-record.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/password.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/get.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/add.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/update.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/batch-approval.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/approval.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/message.routes.ps1")
. (Join-Path -Path $scriptDir -ChildPath "routes/employee/delete.routes.ps1")
