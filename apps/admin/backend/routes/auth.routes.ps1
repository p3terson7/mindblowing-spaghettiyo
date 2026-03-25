        if ($request.Url.AbsolutePath -eq "/auth/login" -and $request.HttpMethod -eq "POST") {
            try {
                $payload = Read-JsonRequestBody -Request $request
                if ($null -eq $payload -or [string]::IsNullOrWhiteSpace([string]$payload.username) -or [string]::IsNullOrWhiteSpace([string]$payload.password)) {
                    respondWithError $response 400 "Username and password are required."
                    continue
                }

                $userRecord = Get-Users | Where-Object {
                    $_.username -eq [string]$payload.username -and -not $_.disabled
                } | Select-Object -First 1

                if ($null -eq $userRecord -or -not (Test-PasswordCredential -Password ([string]$payload.password) -UserRecord $userRecord)) {
                    respondWithError $response 401 "Invalid credentials."
                    continue
                }

                $sessionToken = New-SessionForUser -UserRecord $userRecord
                $result = [PSCustomObject]@{
                    token = $sessionToken
                    user  = [PSCustomObject]@{
                        username           = [string]$userRecord.username
                        displayName        = [string]$userRecord.displayName
                        role               = [string]$userRecord.role
                        employeeCode       = [string]$userRecord.employeeCode
                        mustChangePassword = [bool]$userRecord.mustChangePassword
                    }
                }
                respondWithSuccess $response ($result | ConvertTo-Json -Depth 6)
            }
            catch {
                respondWithError $response 500 "Authentication failed: $($_.Exception.Message)"
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
            respondWithSuccess $response '{ "message": "Logged out successfully." }'
            continue
        }

        if ($request.Url.AbsolutePath -eq "/auth/change-password" -and $request.HttpMethod -eq "POST") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            try {
                $payload = Read-JsonRequestBody -Request $request
                if ($null -eq $payload -or [string]::IsNullOrWhiteSpace([string]$payload.currentPassword) -or [string]::IsNullOrWhiteSpace([string]$payload.newPassword)) {
                    respondWithError $response 400 "Current password and new password are required."
                    continue
                }

                $userRecord = Get-Users | Where-Object { $_.username -eq [string]$currentUser.username } | Select-Object -First 1
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

                Revoke-SessionsForUsername -Username ([string]$currentUser.username) -ExcludeToken ([string]$currentUser.token)

                respondWithSuccess $response '{ "message": "Password updated successfully." }'
            }
            catch {
                respondWithError $response 500 "Password update failed: $($_.Exception.Message)"
            }
            continue
        }
