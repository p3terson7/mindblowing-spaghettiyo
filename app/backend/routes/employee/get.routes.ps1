        # POST /employee/{employeeCode}/gc179-open: Prepare monthly GC179 files locally and launch Acrobat/FDF opening.
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -match "^/employee/(\d+)/gc179-open$") {
            $employeeCode = $matches[1]
            $employeeUser = Get-EmployeeUserByCode -EmployeeCode $employeeCode

            if ($null -eq $employeeUser) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $monthKey = [string]$query["month"]
            try {
                $launch = Start-Gc179LocalExport -EmployeeCode $employeeCode -MonthKey $monthKey
                respondWithSuccess $response ($launch | ConvertTo-Json -Depth 6)
            }
            catch {
                Rethrow-HttpStatusException -Exception $_.Exception
                respondWithError $response 400 $_.Exception.Message
            }
            continue
        }

        # GET /employee/{employeeCode}: Return overtime data
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match "^/employee/(\d+)$") {
            $employeeCode = $matches[1]
            $employeeUser = Get-EmployeeUserByCode -EmployeeCode $employeeCode

            if ($null -eq $employeeUser) {
                respondWithError $response 404 "Employee not found"
                continue
            }

            $employeeName = if ($employeeUser.displayName) { [string]$employeeUser.displayName } else { [string](Get-EmployeeName $employeeCode) }
            $employeeRole = Get-EffectiveUserRole -UserRecord $employeeUser
            # GET is read-only. A missing employee file already projects as an
            # empty collection, so do not probe it once here and again in the
            # read model—or create a shared lock/file as a side effect.
            $dataFile = Get-EmployeeDataFilePath -EmployeeCode $employeeCode
            $entries = @(Get-CachedEmployeeEntriesForFile -DataFile $dataFile)
            $isSuperAdmin = Test-CurrentUserSuperAdmin -CurrentUser $currentUser
            $modifyAccessModel = Get-ProjectModificationAccessModelForCurrentUser -CurrentUser $currentUser
            if (-not $isSuperAdmin) {
                $visibleProjectCodeSet = (Get-ProjectAccessModelForCurrentUser -CurrentUser $currentUser).ProjectCodeSet
                $entries = @($entries | Where-Object {
                    $_ -and
                    $_.PSObject.Properties.Name -contains "projectCode" -and
                    $visibleProjectCodeSet.ContainsKey([string]$_.projectCode)
                })
            }
            $projectedEntries = @()
            $canApproveEmployeeRole = Test-CurrentUserCanApproveEmployeeRole -CurrentUser $currentUser -EmployeeRole $employeeRole
            foreach ($entry in $entries) {
                $projectedEntries += (New-EmployeeEntryProjectionForAccessModel -EmployeeCode $employeeCode -EmployeeName $employeeName -Entry $entry -ModifyProjectCodeSet $modifyAccessModel.ProjectCodeSet -EmployeeRole $employeeRole -IsSuperAdmin:$isSuperAdmin -CanApproveEmployeeRole:$canApproveEmployeeRole)
            }
            $entriesJson = if ($projectedEntries.Count -gt 0) {
                ConvertTo-Json -InputObject @($projectedEntries) -Depth 6
            }
            else {
                "[]"
            }
            respondWithSuccess $response $entriesJson
            continue
        }
