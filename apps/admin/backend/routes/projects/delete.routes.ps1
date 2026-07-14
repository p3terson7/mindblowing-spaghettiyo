        # DELETE /projects/{projectCode}: Archive by default, or permanently delete when requested.
        if ($request.HttpMethod -eq "DELETE" -and $request.Url.AbsolutePath -match "^/projects/([^/]+)$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $projectCode = [System.Uri]::UnescapeDataString([string]$matches[1]).Trim()
            $permanentValue = ""
            if ($request.PSObject.Properties.Name -contains "QueryString" -and $null -ne $request.QueryString) {
                $permanentValue = ([string]$request.QueryString["permanent"]).Trim().ToLowerInvariant()
            }
            $permanentDelete = @("1", "true", "yes") -contains $permanentValue

            $projectMutationCommitted = $false
            $projectMutationError = $null
            try {
                $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
                try {
                    $projects = Get-Projects
                    $projectIndex = -1
                    for ($i = 0; $i -lt $projects.Count; $i++) {
                        if ([string]$projects[$i].projectCode -eq $projectCode) {
                            $projectIndex = $i
                            break
                        }
                    }

                    if ($projectIndex -lt 0) {
                        respondWithError $response 404 "Project with code $projectCode not found."
                        continue
                    }

                    if ($permanentDelete) {
                        $referenceSummary = Get-ProjectEntryReferenceSummary -ProjectCode $projectCode
                        if ([int]$referenceSummary.referenceCount -gt 0) {
                            respondWithError $response 409 "Project cannot be deleted because it is used by $([int]$referenceSummary.referenceCount) overtime entries. Archive it instead."
                            continue
                        }

                        $projects = @($projects | Where-Object { [string]$_.projectCode -ne $projectCode })
                    }
                    else {
                        $projects[$projectIndex].archived = $true
                    }

                    Write-JsonAtomic -Path $projectsFile -Value @($projects) -Depth 6
                    $projectMutationCommitted = $true
                }
                finally {
                    Release-ResourceLock -LockHandle $lockHandle
                }

                if ($permanentDelete) {
                    logHistory "Delete" "Permanently deleted the project <strong>$projectCode</strong>." ([string]$currentUser.displayName)
                }
                else {
                    logHistory "Archive" "Archived the project <strong>$projectCode</strong>." ([string]$currentUser.displayName)
                }
            }
            catch {
                $projectMutationError = $_
                throw
            }
            finally {
                if ($projectMutationCommitted) {
                    try {
                        Publish-DataChange -Category "project" -Resource $projectCode | Out-Null
                    }
                    catch {
                        if ($null -eq $projectMutationError) {
                            throw
                        }

                        Write-Warning "Unable to publish project cache invalidation after a failed project removal operation: $($_.Exception.Message)"
                    }
                }
            }

            $successMessage = if ($permanentDelete) { '{ "message": "Project deleted permanently." }' } else { '{ "message": "Project archived successfully." }' }
            respondWithSuccess $response $successMessage
            continue
        }
