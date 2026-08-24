        if ($request.Url.AbsolutePath -eq "/health" -and $request.HttpMethod -eq "GET") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            $dataFolderWritable = $false
            $dataFolderError = ""
            $healthProbePath = Join-Path -Path $sharedFolder -ChildPath (".health-{0}.tmp" -f ([Guid]::NewGuid().ToString("N")))
            try {
                [System.IO.File]::WriteAllText($healthProbePath, "ok")
                Remove-Item -Path $healthProbePath -Force -ErrorAction SilentlyContinue
                $dataFolderWritable = $true
            }
            catch {
                $dataFolderError = $_.Exception.Message
            }

            $syncState = Get-PublicSyncState
            $gc179TemplatePath = Join-Path -Path $repoRoot -ChildPath "docs/GC179.pdf"
            $checks = @(
                [PSCustomObject]@{
                    key     = "dataFolder"
                    ok      = [bool](Test-Path -Path $sharedFolder -PathType Container)
                    label   = "Data folder"
                    detail  = [string]$sharedFolder
                },
                [PSCustomObject]@{
                    key     = "dataWritable"
                    ok      = [bool]$dataFolderWritable
                    label   = "Data folder writable"
                    detail  = if ($dataFolderWritable) { "Writable" } else { $dataFolderError }
                },
                [PSCustomObject]@{
                    key     = "gc179Template"
                    ok      = [bool](Test-Path -Path $gc179TemplatePath -PathType Leaf)
                    label   = "GC179 template"
                    detail  = [string]$gc179TemplatePath
                }
            )

            $allChecksOk = $true
            foreach ($check in $checks) {
                if (-not [bool]$check.ok) {
                    $allChecksOk = $false
                    break
                }
            }

            $payload = [PSCustomObject]@{
                status           = if ($allChecksOk) { "ok" } else { "warning" }
                serverTimeUtc    = (Get-Date).ToUniversalTime().ToString("o")
                powershell       = [string]$PSVersionTable.PSVersion
                dataFolder       = [string]$sharedFolder
                dataFolderWritable = [bool]$dataFolderWritable
                dataSchema       = [PSCustomObject]@{
                    version        = [int]$dataSchema.schemaVersion
                    minimumReader  = [int]$dataSchema.minimumReaderVersion
                    supported      = [int]$script:SaphirSupportedSchemaVersion
                }
                usersCount       = @((Get-Users) | Where-Object { Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode "" }).Count
                projectsCount    = @((Get-Projects) | Where-Object { -not (Test-ProjectArchived -Project $_) }).Count
                sync             = $syncState
                gc179Template    = [PSCustomObject]@{
                    exists = [bool](Test-Path -Path $gc179TemplatePath -PathType Leaf)
                    path   = [string]$gc179TemplatePath
                }
                checks           = $checks
            }

            respondWithSuccess $response ($payload | ConvertTo-Json -Depth 6)
            continue
        }

        if ($request.Url.AbsolutePath -eq "/sync/status" -and $request.HttpMethod -eq "GET") {
            $currentUser = Get-AuthenticatedUserFromRequest -Request $request
            if ($null -eq $currentUser) {
                respondWithError $response 401 "Authentication required."
                continue
            }

            $state = Get-PublicSyncState
            respondWithSuccess $response ($state | ConvertTo-Json -Depth 6)
            continue
        }
