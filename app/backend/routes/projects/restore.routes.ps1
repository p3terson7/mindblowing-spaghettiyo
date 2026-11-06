        # POST /projects/{projectCode}/restore: Restore an archived project.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/projects/([^/]+)/restore$") {
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                respondWithError $response 403 "Super admin access is required."
                continue
            }

            $projectCode = [System.Uri]::UnescapeDataString([string]$matches[1]).Trim()
            $wasAlreadyActive = $false
            $projectMutationCommitted = $false
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

                        $wasAlreadyActive = -not (Test-ProjectArchived -Project $projects[$projectIndex])
                        if (-not $wasAlreadyActive) {
                            $projects[$projectIndex].archived = $false
                            Write-JsonArrayAtomic -Path $projectsFile -Items $projects -Depth 6
                            $script:ProjectsCache = $null
                            $projectMutationCommitted = $true
                        }
                    }
                    finally {
                        Release-ResourceLock -LockHandle $lockHandle
                    }
                }
                finally {
                    Release-ResourceLock -LockHandle $referenceLockHandle
                }

                if (-not $wasAlreadyActive) {
                    $historyWarning = Invoke-PostCommitActionSafely -Description "Project restored, but history logging failed" -Action {
                        logHistory "Update" "Restored the project <strong>$projectCode</strong>." ([string]$currentUser.displayName) -PublishChange:$false
                    }
                    if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
                        [void]$postCommitWarnings.Add($historyWarning)
                    }
                }

                if ($projectMutationCommitted -or $wasAlreadyActive) {
                    $cacheWarning = Invoke-PostCommitActionSafely -Description "Project restored, but local cache invalidation failed" -Action {
                        Clear-LocalProjectMutationCaches
                    }
                    if (-not [string]::IsNullOrWhiteSpace($cacheWarning)) {
                        [void]$postCommitWarnings.Add($cacheWarning)
                    }
                }

                # Publish even for an idempotent retry so another workstation
                # that missed the first notification can refresh its catalog.
                $syncWarning = Invoke-PostCommitActionSafely -Description "Project restored, but cross-machine refresh publication failed" -Action {
                    Publish-DataChange -Category "project" -Resource $projectCode | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
                    [void]$postCommitWarnings.Add($syncWarning)
                }

                respondWithSuccess $response (([PSCustomObject]@{
                    message       = if ($wasAlreadyActive) { "Project was already active." } else { "Project restored successfully." }
                    projectCode   = $projectCode
                    alreadyActive = $wasAlreadyActive
                    warnings      = @($postCommitWarnings.ToArray())
                }) | ConvertTo-Json -Depth 4)
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                Write-Warning ("Unable to restore project {0}: {1}" -f $projectCode, $_.Exception.Message)
                respondWithError $response 500 "Unable to restore project."
            }
            continue
        }
