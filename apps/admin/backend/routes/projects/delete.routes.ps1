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
            $postCommitWarnings = New-Object System.Collections.ArrayList
            try {
                $referenceLockHandle = Acquire-ProjectReferenceLock
                try {
                    $lockHandle = Acquire-ResourceLock -ResourcePath $projectsFile
                    try {
                        $projects = @(Read-ProjectsFromDisk)
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

                        Write-JsonArrayAtomic -Path $projectsFile -Items $projects -Depth 6
                        $script:ProjectsCache = $null
                        $projectMutationCommitted = $true
                    }
                    finally {
                        Release-ResourceLock -LockHandle $lockHandle
                    }
                }
                finally {
                    Release-ResourceLock -LockHandle $referenceLockHandle
                }

                $historyWarning = Invoke-PostCommitActionSafely -Description "Project removal saved, but history logging failed" -Action {
                    if ($permanentDelete) {
                        logHistory "Delete" "Permanently deleted the project <strong>$projectCode</strong>." ([string]$currentUser.displayName) -PublishChange:$false
                    }
                    else {
                        logHistory "Archive" "Archived the project <strong>$projectCode</strong>." ([string]$currentUser.displayName) -PublishChange:$false
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                    [void]$postCommitWarnings.Add($historyWarning)
                }
            }
            catch {
                $projectMutationError = $_
                throw
            }
            finally {
                if ($projectMutationCommitted) {
                    $syncWarning = Invoke-PostCommitActionSafely -Description "Project removal saved, but cross-machine refresh publication failed" -Action {
                        Publish-DataChange -Category "project" -Resource $projectCode | Out-Null
                    }
                    if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                        [void]$postCommitWarnings.Add($syncWarning)
                    }
                }
            }

            $successMessage = if ($permanentDelete) { "Project deleted permanently." } else { "Project archived successfully." }
            respondWithSuccess $response (([PSCustomObject]@{
                message = $successMessage
                warnings = @($postCommitWarnings.ToArray())
            }) | ConvertTo-Json -Depth 4)
            continue
        }
