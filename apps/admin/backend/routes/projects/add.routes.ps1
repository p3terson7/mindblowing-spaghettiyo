        # POST /projects: Create a new project.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/projects") {
            $payload = Read-JsonRequestBody -Request $request
            
            # Validate that projectCode and projectName are provided.
            if (-not ($payload.projectCode -and $payload.projectName)) {
                respondWithError $response 400 "Missing required fields: projectCode and projectName are required."
                continue
            }

            $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
            try {
                $projects = Get-Projects

                # Check for duplicate projectCode.
                if ($projects | Where-Object { $_.projectCode -eq $payload.projectCode }) {
                    respondWithError $response 400 "Project with code $($payload.projectCode) already exists."
                    continue
                }

                # Append the new project.
                $projects += [PSCustomObject]@{
                    projectCode = [string]$payload.projectCode
                    projectName = [string]$payload.projectName
                }
                Write-JsonAtomic -Path $projectsFile -Value $projects -Depth 6
            }
            finally {
                Release-ResourceLock -LockHandle $lockHandle
            }

            Publish-DataChange -Category "project" -Resource ([string]$payload.projectCode)
            respondWithSuccess $response '{ "message": "Project added successfully." }'
            continue
        }
