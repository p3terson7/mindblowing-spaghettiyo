        # GET /employee/{employeeCode}/gc179-fdf: Return a monthly FDF import file for the GC179 PDF.
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/employee/(\d+)/gc179-fdf$") {
            $employeeCode = $matches[1]
            $employeeUser = Get-Users | Where-Object { Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode $employeeCode } | Select-Object -First 1

            if ($null -eq $employeeUser) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $monthKey = [string]$query["month"]
            try {
                $export = New-Gc179FdfExport -EmployeeCode $employeeCode -MonthKey $monthKey
                $bytes = [System.Text.Encoding]::ASCII.GetBytes([string]$export.Content)
                respondWithDownload $response $bytes "application/vnd.fdf" ([string]$export.FileName)
            }
            catch {
                respondWithError $response 400 $_.Exception.Message
            }
            continue
        }

        # GET /employee/{employeeCode}: Return overtime data
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/employee/(\d+)$") {
            $employeeCode = $matches[1]
            $employeeUser = Get-Users | Where-Object { Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode $employeeCode } | Select-Object -First 1

            if ($null -eq $employeeUser) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $employeeName = if ($employeeUser.displayName) { [string]$employeeUser.displayName } else { [string](Get-EmployeeName $employeeCode) }
            $employeeRole = Get-EffectiveUserRole -UserRecord $employeeUser
            $dataFile = Ensure-EmployeeDataFile -EmployeeCode $employeeCode
            $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)
            if (-not (Test-CurrentUserSuperAdmin -CurrentUser $currentUser)) {
                $visibleProjectCodeSet = (Get-ProjectAccessModelForCurrentUser -CurrentUser $currentUser).ProjectCodeSet
                $entries = @($entries | Where-Object {
                    $_ -and
                    $_.PSObject.Properties.Name -contains "projectCode" -and
                    $visibleProjectCodeSet.ContainsKey([string]$_.projectCode)
                })
            }
            $projectedEntries = @()
            foreach ($entry in $entries) {
                $projectedEntries += (New-EmployeeEntryProjectionForCurrentUser -EmployeeCode $employeeCode -EmployeeName $employeeName -Entry $entry -CurrentUser $currentUser -EmployeeRole $employeeRole)
            }
            $entriesJson = if ($projectedEntries.Count -gt 0) {
                $projectedEntries | ConvertTo-Json -Depth 6
            }
            else {
                "[]"
            }
            respondWithSuccess $response $entriesJson
            continue
        }
