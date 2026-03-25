        if ($request.Url.AbsolutePath -eq "/sync/status" -and $request.HttpMethod -eq "GET") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            $state = Get-SyncState
            respondWithSuccess $response ($state | ConvertTo-Json -Depth 6)
            continue
        }
