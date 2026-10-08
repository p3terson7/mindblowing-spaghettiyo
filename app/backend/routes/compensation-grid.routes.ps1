# Shared compensation configuration is intentionally isolated from employee
# and GC179 routes. The grid contains departmental pay bands, so only super
# administrators may read or modify it.
if ($request.Url.AbsolutePath -match "^/compensation-grid/?$") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
        respondWithError $response 403 "Super admin access is required."
        continue
    }

    if ($request.HttpMethod -eq "GET") {
        try {
            $grid = Get-CompensationGrid
            respondWithSuccess $response ($grid | ConvertTo-Json -Depth 12)
        }
        catch {
            Rethrow-HttpStatusException -Exception $_.Exception
            Write-Warning ("Unable to read compensation grid: {0}" -f $_.Exception.Message)
            respondWithError $response 500 "Unable to read the compensation grid."
        }
        continue
    }

    if ($request.HttpMethod -eq "PUT") {
        try {
            $payload = Read-JsonRequestBody -Request $request
            if ($null -eq $payload -or -not ($payload.PSObject.Properties.Name -contains "bands")) {
                respondWithError $response 400 "A compensation grid with salary bands is required."
                continue
            }

            $grid = Set-CompensationGrid -Bands $payload.bands
            $postCommitWarnings = New-Object System.Collections.ArrayList
            $historyWarning = Invoke-PostCommitActionSafely -Description "Compensation grid saved, but history logging failed" -Action {
                # Do not put salary amounts in the manager-visible history.
                logHistory "Update" "Updated the shared compensation grid." ([string]$currentUser.displayName) -PublishChange:$false
            }
            if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                [void]$postCommitWarnings.Add($historyWarning)
            }

            $syncWarning = Invoke-PostCommitActionSafely -Description "Compensation grid saved, but cross-machine refresh publication failed" -Action {
                Publish-DataChange -Category "compensation" -Resource "shared" | Out-Null
            }
            if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                [void]$postCommitWarnings.Add($syncWarning)
            }

            respondWithSuccess $response (([PSCustomObject][ordered]@{
                message       = "Compensation grid saved successfully."
                schemaVersion = [int]$grid.schemaVersion
                currency      = [string]$grid.currency
                bands         = @($grid.bands)
                warnings      = @($postCommitWarnings.ToArray())
            }) | ConvertTo-Json -Depth 12)
        }
        catch [System.ArgumentException] {
            respondWithError $response 400 $_.Exception.Message
        }
        catch {
            Rethrow-HttpStatusException -Exception $_.Exception
            Write-Warning ("Unable to save compensation grid: {0}" -f $_.Exception.Message)
            respondWithError $response 500 "Unable to save the compensation grid."
        }
        continue
    }

    $response.Headers["Allow"] = "GET, PUT"
    respondWithError $response 405 "Method not allowed."
    continue
}
