if ($request.Url.AbsolutePath -match "^/budget-periods/?$") {
    $currentUser = Get-AuthenticatedUserFromRequest -Request $request
    if ($null -eq $currentUser) {
        respondWithError $response 401 "Authentication required."
        continue
    }
    if (-not (Test-CurrentUserManager -CurrentUser $currentUser)) {
        respondWithError $response 403 "Manager access is required."
        continue
    }

    if ($request.HttpMethod -eq "GET") {
        try {
            $configuration = Get-BudgetPeriodConfiguration
            respondWithSuccess $response ($configuration | ConvertTo-Json -Depth 8)
        }
        catch {
            Rethrow-HttpStatusException -Exception $_.Exception
            Write-Warning ("Unable to read budget periods: {0}" -f $_.Exception.Message)
            respondWithError $response 500 "Unable to read the budget periods."
        }
        continue
    }

    if ($request.HttpMethod -eq "PUT") {
        if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
            respondWithError $response 403 "Super admin access is required."
            continue
        }

        try {
            $payload = Read-JsonRequestBody -Request $request
            if ($null -eq $payload -or -not ($payload.PSObject.Properties.Name -contains "periods")) {
                respondWithError $response 400 "A budget-period configuration is required."
                continue
            }

            $configuration = Set-BudgetPeriodConfiguration -CycleLabel ([string]$payload.cycleLabel) -Periods $payload.periods
            $postCommitWarnings = New-Object System.Collections.ArrayList
            $historyWarning = Invoke-PostCommitActionSafely -Description "Budget periods saved, but history logging failed" -Action {
                logHistory "Update" "Updated the shared budget periods." ([string]$currentUser.displayName) -PublishChange:$false
            }
            if ($historyWarning) {
                [void]$postCommitWarnings.Add($historyWarning)
            }
            $syncWarning = Invoke-PostCommitActionSafely -Description "Budget periods saved, but cross-machine refresh publication failed" -Action {
                Publish-DataChange -Category "budget-periods" -Resource "shared" | Out-Null
            }
            if ($syncWarning) {
                [void]$postCommitWarnings.Add($syncWarning)
            }

            respondWithSuccess $response (([PSCustomObject][ordered]@{
                message       = "Budget periods saved successfully."
                schemaVersion = [int]$configuration.schemaVersion
                cycleLabel    = [string]$configuration.cycleLabel
                periods       = @($configuration.periods)
                warnings      = @($postCommitWarnings.ToArray())
            }) | ConvertTo-Json -Depth 8)
        }
        catch [System.ArgumentException] {
            respondWithError $response 400 $_.Exception.Message
        }
        catch {
            Rethrow-HttpStatusException -Exception $_.Exception
            Write-Warning ("Unable to save budget periods: {0}" -f $_.Exception.Message)
            respondWithError $response 500 "Unable to save the budget periods."
        }
        continue
    }

    $response.Headers["Allow"] = "GET, PUT"
    respondWithError $response 405 "Method not allowed."
    continue
}
