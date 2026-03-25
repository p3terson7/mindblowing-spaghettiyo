$currentUser = Get-AuthenticatedUserFromRequest -Request $request
if ($request.Url.AbsolutePath -eq "/history") {
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserRole -CurrentUser $currentUser -AllowedRoles @("admin"))) {
        respondWithError $response 403 "Admin access is required."
        continue
    }
}

        # GET /history Endpoint
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/history") {
            try {
                # Ensure history file exists.
                if (!(Test-Path -Path $historyFile)) {
                    Write-JsonAtomic -Path $historyFile -Value @()
                }
                $historyContent = (Read-JsonArrayFile -Path $historyFile | ConvertTo-Json -Depth 6)
                respondWithSuccess $response $historyContent
            }
            catch {
                respondWithError $response 500 "Error reading history: $($_.Exception.Message)"
            }
            continue
        }
