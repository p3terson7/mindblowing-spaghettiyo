function Get-DemoSeedRandomItem {
    param($Items)

    $source = @($Items)
    if ($source.Count -eq 0) {
        return $null
    }

    return $source[(Get-Random -Minimum 0 -Maximum $source.Count)]
}

function Get-DemoSeedShuffledItems {
    param($Items)

    $list = New-Object System.Collections.ArrayList
    foreach ($item in @($Items)) {
        [void]$list.Add($item)
    }

    $result = @()
    while ($list.Count -gt 0) {
        $index = Get-Random -Minimum 0 -Maximum $list.Count
        $result += $list[$index]
        $list.RemoveAt($index)
    }

    return $result
}

function Get-DemoSeedNearAllCount {
    param([int]$Count)

    if ($Count -le 0) {
        return 0
    }

    if ($Count -le 5) {
        return $Count
    }

    $maxSkipped = [math]::Min(2, [math]::Max(1, [int][math]::Floor($Count * 0.1)))
    $skipped = Get-Random -Minimum 0 -Maximum ($maxSkipped + 1)
    return [math]::Max(1, ($Count - $skipped))
}

function Get-DemoSeedOptionCodes {
    param(
        $Options,
        [bool]$AllowBlank = $false,
        [string]$Fallback = ""
    )

    $codes = @(
        @($Options) |
            Where-Object {
                if ($null -eq $_ -or -not ($_.PSObject.Properties.Name -contains "code")) {
                    $false
                }
                else {
                    $code = [string]$_.code
                    if ([string]::IsNullOrWhiteSpace($code)) {
                        $AllowBlank
                    }
                    else {
                        $true
                    }
                }
            } |
            ForEach-Object { [string]$_.code }
    )

    if ($codes.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($Fallback)) {
        return @($Fallback)
    }

    return @($codes)
}

function Get-DemoSeedActiveEmployees {
    $employees = @()
    $users = @(Get-Users | Where-Object { (Test-EmployeeUserRecord -UserRecord $_ -EmployeeCode "") -and -not [bool]$_.disabled })

    foreach ($user in ($users | Sort-Object username)) {
        $employeeCode = Get-UserEmployeeCodeValue -UserRecord $user
        if ([string]::IsNullOrWhiteSpace($employeeCode)) {
            continue
        }

        $displayName = if ($user.displayName) { [string]$user.displayName } else { [string](Get-EmployeeName $employeeCode) }
        $employees += [PSCustomObject]@{
            code = $employeeCode
            name = $displayName
            role = Get-EffectiveUserRole -UserRecord $user
        }
    }

    return @($employees)
}

function New-DemoSeedAssignments {
    param(
        [Parameter(Mandatory = $true)]$Employees,
        [Parameter(Mandatory = $true)]$Projects
    )

    $assignments = @{}
    foreach ($employee in @($Employees)) {
        $assignments[[string]$employee.code] = @()
    }

    $employeeList = @($Employees)
    $projectList = @($Projects)
    if ($employeeList.Count -eq 0 -or $projectList.Count -eq 0) {
        return $assignments
    }

    for ($i = 0; $i -lt $projectList.Count; $i++) {
        $project = $projectList[$i]
        $assigned = $false
        for ($attempt = 0; $attempt -lt $employeeList.Count; $attempt++) {
            $employee = $employeeList[($i + $attempt) % $employeeList.Count]
            $employeeCode = [string]$employee.code
            $currentProjects = @($assignments[$employeeCode])
            if ($currentProjects.Count -lt 2) {
                $currentProjects += $project
                $assignments[$employeeCode] = @($currentProjects)
                $assigned = $true
                break
            }
        }

        if (-not $assigned) {
            break
        }
    }

    foreach ($employee in $employeeList) {
        $employeeCode = [string]$employee.code
        $currentProjects = @($assignments[$employeeCode])
        if ($currentProjects.Count -eq 0) {
            $assignments[$employeeCode] = @((Get-DemoSeedRandomItem -Items $projectList))
            continue
        }

        $shouldAddSecondProject = ((Get-Random -Minimum 1 -Maximum 101) -le 35)
        if ($currentProjects.Count -lt 2 -and $projectList.Count -gt 1 -and $shouldAddSecondProject) {
            $currentCodes = @($currentProjects | ForEach-Object { [string]$_.projectCode })
            $remainingProjects = @($projectList | Where-Object { $currentCodes -notcontains [string]$_.projectCode })
            if ($remainingProjects.Count -gt 0) {
                $currentProjects += (Get-DemoSeedRandomItem -Items $remainingProjects)
                $assignments[$employeeCode] = @($currentProjects)
            }
        }
    }

    return $assignments
}

function Get-DemoSeedStatus {
    $roll = Get-Random -Minimum 1 -Maximum 101
    if ($roll -le 68) {
        return "approved"
    }
    if ($roll -le 90) {
        return "pending"
    }
    return "rejected"
}

function Get-DemoSeedManagerMessage {
    param([string]$Status)

    if ([string]$Status -eq "rejected") {
        return (Get-DemoSeedRandomItem -Items @(
            "A valider avec le superviseur avant approbation.",
            "Information incomplete pour cette entree.",
            "Verification requise pour le formulaire mensuel."
        ))
    }

    $roll = Get-Random -Minimum 1 -Maximum 101
    if ($roll -le 8) {
        return (Get-DemoSeedRandomItem -Items @(
            "Valide avec le projet.",
            "Ajustement confirme.",
            "Note ajoutee pour le suivi mensuel."
        ))
    }

    return ""
}

function New-DemoSeedEntry {
    param(
        [Parameter(Mandatory = $true)]$Employee,
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)]$OvertimeCodes,
        [Parameter(Mandatory = $true)]$PaymentOptions,
        [Parameter(Mandatory = $true)]$ReasonCodes,
        [int]$MonthsBack = 6,
        [Parameter(Mandatory = $true)][string]$BatchId
    )

    $safeMonthsBack = [math]::Max(1, $MonthsBack)
    $maxDaysBack = [math]::Max(14, ($safeMonthsBack * 31))
    $daysBack = Get-Random -Minimum 2 -Maximum ($maxDaysBack + 1)
    $baseDate = (Get-Date).Date.AddDays(-1 * $daysBack)
    $startHour = Get-DemoSeedRandomItem -Items @(6, 7, 15, 16, 17, 18)
    $startMinute = Get-DemoSeedRandomItem -Items @(0, 15, 30, 45)
    $startOffset = Get-Random -Minimum -7 -Maximum 8
    $durationMinutes = Get-DemoSeedRandomItem -Items @(60, 75, 90, 105, 120, 150, 180, 210)
    $endOffset = Get-Random -Minimum -5 -Maximum 6

    $exactStart = $baseDate.AddHours($startHour).AddMinutes($startMinute).AddMinutes($startOffset)
    $exactEnd = $exactStart.AddMinutes($durationMinutes).AddMinutes($endOffset)
    if ($exactEnd.Date -ne $exactStart.Date) {
        $exactEnd = $exactStart.AddMinutes($durationMinutes)
    }

    $dateText = $exactStart.ToString("yyyy-MM-dd")
    $exactPunchIn = $exactStart.ToString("HH:mm:ss")
    $exactPunchOut = $exactEnd.ToString("HH:mm:ss")
    $punchInRounded = Convert-ToNearestQuarterHourText -Date $dateText -TimeText $exactPunchIn
    $punchOutRounded = Convert-ToNearestQuarterHourText -Date $dateText -TimeText $exactPunchOut
    $punchInTime = [DateTime]::ParseExact(("{0} {1}" -f $dateText, $punchInRounded), "yyyy-MM-dd HH:mm:ss", $null)
    $punchOutTime = [DateTime]::ParseExact(("{0} {1}" -f $dateText, $punchOutRounded), "yyyy-MM-dd HH:mm:ss", $null)

    if ($punchOutTime -le $punchInTime) {
        $punchOutTime = $punchInTime.AddMinutes(15)
        $punchOutRounded = $punchOutTime.ToString("HH:mm:ss")
        $exactPunchOut = $punchOutRounded
    }

    $status = Get-DemoSeedStatus

    return [PSCustomObject]@{
        entryId = New-EntryIdentifier
        name = [string]$Employee.name
        date = $dateText
        punchIn = $punchInRounded
        exactPunchIn = $exactPunchIn
        punchOut = $punchOutRounded
        exactPunchOut = $exactPunchOut
        overtime = ($punchOutTime - $punchInTime).ToString("hh\:mm\:ss")
        status = $status
        message = Get-DemoSeedManagerMessage -Status $status
        projectCode = [string]$Project.projectCode
        overtimeCode = [string](Get-DemoSeedRandomItem -Items $OvertimeCodes)
        paymentOption = [string](Get-DemoSeedRandomItem -Items $PaymentOptions)
        reasonCode = [string](Get-DemoSeedRandomItem -Items $ReasonCodes)
        seedBatchId = $BatchId
        seededAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function New-DemoOvertimeEntries {
    param(
        $CurrentUser,
        [int]$MinimumEntriesPerEmployee = 4,
        [int]$MaximumEntriesPerEmployee = 8,
        [int]$MonthsBack = 6
    )

    if ($null -ne $CurrentUser -and -not (Test-CurrentUserSuperAdmin -CurrentUser $CurrentUser)) {
        throw "Super admin access is required to seed demo entries."
    }

    $minimumEntries = [math]::Max(1, $MinimumEntriesPerEmployee)
    $maximumEntries = [math]::Max($minimumEntries, $MaximumEntriesPerEmployee)
    $activeEmployees = @(Get-DemoSeedActiveEmployees)
    $activeProjects = @(Get-ActiveProjects)

    if ($activeEmployees.Count -eq 0) {
        throw "Create at least one active employee before seeding demo entries."
    }

    if ($activeProjects.Count -eq 0) {
        throw "Create at least one active project before seeding demo entries."
    }

    $employeeTargetCount = Get-DemoSeedNearAllCount -Count $activeEmployees.Count
    $maxCoverableProjects = [math]::Max(1, ($employeeTargetCount * 2))
    $projectTargetCount = [math]::Min((Get-DemoSeedNearAllCount -Count $activeProjects.Count), $maxCoverableProjects)
    $selectedEmployees = @((Get-DemoSeedShuffledItems -Items $activeEmployees) | Select-Object -First $employeeTargetCount)
    $selectedProjects = @((Get-DemoSeedShuffledItems -Items $activeProjects) | Select-Object -First $projectTargetCount)
    $assignments = New-DemoSeedAssignments -Employees $selectedEmployees -Projects $selectedProjects
    $overtimeCodes = @(Get-DemoSeedOptionCodes -Options (Get-OvertimeCodes) -AllowBlank:$false -Fallback "260")
    $paymentOptions = @(Get-DemoSeedOptionCodes -Options (Get-PaymentOptions) -AllowBlank:$false -Fallback "cash")
    $reasonCodes = @(Get-DemoSeedOptionCodes -Options (Get-ReasonCodes) -AllowBlank:$false -Fallback "D")
    $batchId = [Guid]::NewGuid().ToString("N")
    $entryCount = 0
    $writtenEmployees = @()
    $usedProjectCodes = @{}

    foreach ($employee in $selectedEmployees) {
        $employeeCode = [string]$employee.code
        $assignedProjects = @($assignments[$employeeCode])
        if ($assignedProjects.Count -eq 0) {
            continue
        }

        $employeeEntryCount = Get-Random -Minimum $minimumEntries -Maximum ($maximumEntries + 1)
        $entriesToAdd = @()
        foreach ($project in $assignedProjects) {
            if ($entriesToAdd.Count -ge $employeeEntryCount) {
                break
            }

            $entriesToAdd += (New-DemoSeedEntry -Employee $employee -Project $project -OvertimeCodes $overtimeCodes -PaymentOptions $paymentOptions -ReasonCodes $reasonCodes -MonthsBack $MonthsBack -BatchId $batchId)
            $usedProjectCodes[[string]$project.projectCode] = $true
        }

        while ($entriesToAdd.Count -lt $employeeEntryCount) {
            $project = Get-DemoSeedRandomItem -Items $assignedProjects
            $entriesToAdd += (New-DemoSeedEntry -Employee $employee -Project $project -OvertimeCodes $overtimeCodes -PaymentOptions $paymentOptions -ReasonCodes $reasonCodes -MonthsBack $MonthsBack -BatchId $batchId)
            $usedProjectCodes[[string]$project.projectCode] = $true
        }

        $dataFile = Ensure-EmployeeDataFile -EmployeeCode $employeeCode
        $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
        try {
            $existingEntries = @(Read-JsonArrayFile -Path $dataFile)
            foreach ($entry in $entriesToAdd) {
                $existingEntries += $entry
            }
            Write-JsonArrayAtomic -Path $dataFile -Items $existingEntries -Depth 8
        }
        finally {
            Release-ResourceLock -LockHandle $lockHandle
        }

        $entryCount += $entriesToAdd.Count
        $writtenEmployees += [PSCustomObject]@{
            code = $employeeCode
            name = [string]$employee.name
            projectCodes = @($assignedProjects | ForEach-Object { [string]$_.projectCode })
            entryCount = $entriesToAdd.Count
        }
    }

    if ($entryCount -gt 0) {
        $historyMessage = "Generated <strong>$entryCount</strong> demo overtime entries for <strong>$($writtenEmployees.Count)</strong> employees across <strong>$($usedProjectCodes.Keys.Count)</strong> projects."
        $null = logHistory "Seed" $historyMessage "Demo data" -PublishChange:$false
        $null = Publish-DataChange -Category "seed" -Resource $batchId
    }

    return [PSCustomObject]@{
        message = "Demo overtime entries generated."
        batchId = $batchId
        entryCount = [int]$entryCount
        employeeCount = [int]$writtenEmployees.Count
        projectCount = [int]$usedProjectCodes.Keys.Count
        selectedProjectCount = [int]$selectedProjects.Count
        monthsBack = [int]$MonthsBack
        employees = @($writtenEmployees)
    }
}
