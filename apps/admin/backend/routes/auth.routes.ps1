        if ($request.Url.AbsolutePath -eq "/auth/login" -and $request.HttpMethod -eq "POST") {
            $response.Headers["Cache-Control"] = "no-store"
            try {
                try {
                    $payload = Read-JsonRequestBody -Request $request
                }
                catch [System.FormatException] {
                    respondWithError $response 400 $_.Exception.Message
                    continue
                }
                catch [System.IO.InvalidDataException] {
                    respondWithError $response 413 "The request body is too large."
                    continue
                }
                catch [System.TimeoutException] {
                    respondWithError $response 408 "Timed out while reading the request body."
                    continue
                }

                if ($null -eq $payload -or [string]::IsNullOrWhiteSpace([string]$payload.username) -or [string]::IsNullOrWhiteSpace([string]$payload.password)) {
                    respondWithError $response 400 "Username and password are required."
                    continue
                }

                $username = ([string]$payload.username).Trim()
                $throttleDecision = Get-LoginThrottleDecision -Request $request -Username $username
                if (-not [bool]$throttleDecision.Allowed) {
                    $response.Headers["Retry-After"] = [string]$throttleDecision.RetryAfterSeconds
                    respondWithError $response 429 "Too many sign-in attempts. Try again later."
                    continue
                }

                $userRecord = Get-UserByUsername -Username $username
                $credentialRecord = if ($null -ne $userRecord -and -not [bool]$userRecord.disabled) {
                    $userRecord
                }
                else {
                    Get-DummyLoginCredential
                }
                $passwordMatches = Test-PasswordCredential -Password ([string]$payload.password) -UserRecord $credentialRecord
                if ($null -eq $userRecord -or [bool]$userRecord.disabled -or -not $passwordMatches) {
                    Register-FailedLoginAttempt -Request $request -Username $username
                    respondWithError $response 401 "Invalid credentials."
                    continue
                }

                Clear-LoginThrottleForPrincipal -Request $request -Username $username
                $sessionToken = New-SessionForUser -UserRecord $userRecord
                $userProjection = New-AuthenticatedUserProjection -UserRecord $userRecord -Token $sessionToken
                $result = [PSCustomObject]@{
                    token = $sessionToken
                    user  = [PSCustomObject]@{
                        username           = [string]$userProjection.username
                        displayName        = [string]$userProjection.displayName
                        role               = [string]$userProjection.role
                        employeeCode       = [string]$userProjection.employeeCode
                        mustChangePassword = [bool]$userProjection.mustChangePassword
                        timeEntryTypes     = @($userProjection.timeEntryTypes)
                        gc179Profile       = $userProjection.gc179Profile
                        demoSeedEnabled    = [bool]$demoSeedEnabled
                        gc179ImportEnabled = [bool]$gc179ImportEnabled
                    }
                }
                $response.Headers["Set-Cookie"] = Get-SessionCookieHeader -Token $sessionToken
                respondWithSuccess $response ($result | ConvertTo-Json -Depth 6)
            }
            catch {
                Write-Warning ("Authentication request failed: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Authentication failed."
            }
            continue
        }

        if ($request.Url.AbsolutePath -eq "/auth/me" -and $request.HttpMethod -eq "GET") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            $result = [PSCustomObject]@{
                username           = [string]$currentUser.username
                displayName        = [string]$currentUser.displayName
                role               = [string]$currentUser.role
                employeeCode       = [string]$currentUser.employeeCode
                mustChangePassword = [bool]$currentUser.mustChangePassword
                timeEntryTypes     = @($currentUser.timeEntryTypes)
                gc179Profile       = $currentUser.gc179Profile
                demoSeedEnabled    = [bool]$demoSeedEnabled
                gc179ImportEnabled = [bool]$gc179ImportEnabled
            }
            respondWithSuccess $response ($result | ConvertTo-Json -Depth 6)
            continue
        }

        if ($request.Url.AbsolutePath -eq "/auth/logout" -and $request.HttpMethod -eq "POST") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            Revoke-SessionToken -Token $currentUser.token
            $response.Headers["Set-Cookie"] = Get-ExpiredSessionCookieHeader
            respondWithSuccess $response '{ "message": "Logged out successfully." }'
            continue
        }

        if ($request.Url.AbsolutePath -eq "/auth/change-password" -and $request.HttpMethod -eq "POST") {
            $response.Headers["Cache-Control"] = "no-store"
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            try {
                try {
                    $payload = Read-JsonRequestBody -Request $request
                }
                catch [System.FormatException] {
                    respondWithError $response 400 $_.Exception.Message
                    continue
                }
                catch [System.IO.InvalidDataException] {
                    respondWithError $response 413 "The request body is too large."
                    continue
                }
                catch [System.TimeoutException] {
                    respondWithError $response 408 "Timed out while reading the request body."
                    continue
                }

                if ($null -eq $payload -or [string]::IsNullOrWhiteSpace([string]$payload.currentPassword) -or [string]::IsNullOrWhiteSpace([string]$payload.newPassword)) {
                    respondWithError $response 400 "Current password and new password are required."
                    continue
                }

                $userRecord = Get-UserByUsername -Username ([string]$currentUser.username)
                if ($null -eq $userRecord -or -not (Test-PasswordCredential -Password ([string]$payload.currentPassword) -UserRecord $userRecord)) {
                    respondWithError $response 401 "Current password is invalid."
                    continue
                }

                $policyError = Test-NewPasswordPolicy -Password ([string]$payload.newPassword)
                if ($policyError) {
                    respondWithError $response 400 $policyError
                    continue
                }

                if (-not (Set-UserPassword -Username ([string]$currentUser.username) -NewPassword ([string]$payload.newPassword)) ) {
                    respondWithError $response 500 "Unable to update password."
                    continue
                }

                $postCommitWarnings = New-Object System.Collections.ArrayList
                $revokeWarning = Invoke-PostCommitActionSafely -Description "Password changed, but other sessions could not be revoked" -Action {
                    Revoke-SessionsForUsername -Username ([string]$currentUser.username) -ExcludeToken ([string]$currentUser.token)
                }
                if (-not [string]::IsNullOrWhiteSpace($revokeWarning)) {
                    [void]$postCommitWarnings.Add($revokeWarning)
                }

                $publishWarning = Invoke-PostCommitActionSafely -Description "Password changed, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "auth" -Resource ([string]$currentUser.username) | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($publishWarning)) {
                    [void]$postCommitWarnings.Add($publishWarning)
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message  = "Password updated successfully."
                    warnings = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                Write-Warning ("Password update failed: {0}" -f $_.Exception.Message)
                respondWithError $response 500 "Password update failed."
            }
            continue
        }
