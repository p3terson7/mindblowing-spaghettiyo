if ($request.HttpMethod -eq "PUT" -and $request.Url.AbsolutePath -match "^/employee/(\d+)/work-schedule/month$") {
    $employeeCode = $matches[1]
    $dataFile = Join-Path -Path $sharedFolder -ChildPath "${employeeCode}_data.json"

    if (Test-CurrentUserMatchesEmployeeCode -CurrentUser $currentUser -EmployeeCode $employeeCode) {
        respondWithError $response 403 "Administrators cannot update entries in their own employee profile."
        continue
    }
    if (-not (Test-SaphirFileExists -Path $dataFile)) {
        respondWithError $response 404 "Employee not found"
        continue
    }

    $payload = Read-JsonRequestBody -Request $request
    $month = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "month") { ([string]$payload.month).Trim() } else { "" }
    $workSchedule = if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "workSchedule") { ([string]$payload.workSchedule).Trim().ToLowerInvariant() } else { "" }
    $parsedMonth = [datetime]::MinValue
    if ($month -notmatch "^\d{4}-(0[1-9]|1[0-2])$" -or
        -not [datetime]::TryParseExact("$month-01", "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedMonth)) {
        respondWithError $response 400 "Month must use the yyyy-MM format."
        continue
    }
    if ($workSchedule -notin @("regular", "compressed")) {
        respondWithError $response 400 "workSchedule must be regular or compressed."
        continue
    }

    $updatedCount = 0
    $alreadyConfirmedCount = 0
    $unauthorizedCount = 0
    $postCommitWarnings = New-Object System.Collections.ArrayList
    $lockHandle = $null
    try {
        $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
        $entries = @(Read-JsonArrayFile -Path $dataFile)
        foreach ($entry in $entries) {
            $entryDate = if ($null -ne $entry -and $entry.PSObject.Properties.Name -contains "date") { [string]$entry.date } else { "" }
            if (-not $entryDate.StartsWith("$month-", [StringComparison]::Ordinal)) {
                continue
            }

            $storedSchedule = if ($entry.PSObject.Properties.Name -contains "workSchedule") { ([string]$entry.workSchedule).Trim().ToLowerInvariant() } else { "" }
            if ($storedSchedule -in @("regular", "compressed")) {
                $alreadyConfirmedCount++
                continue
            }
            if (-not (Test-CurrentUserCanManageEntry -CurrentUser $currentUser -Entry $entry)) {
                $unauthorizedCount++
                continue
            }

            Set-EntryPropertyValue -Entry $entry -Name "workSchedule" -Value $workSchedule
            Set-EntryPropertyValue -Entry $entry -Name "workScheduleSource" -Value "supervisor-month-bulk"
            $updatedCount++
        }

        if ($updatedCount -gt 0) {
            Write-JsonArrayAtomic -Path $dataFile -Items $entries -Depth 8
        }
    }
    catch {
        Rethrow-HttpStatusException -Exception $_.Exception
        Write-Warning ("Unable to bulk update employee work schedules: {0}" -f $_.Exception.Message)
        respondWithError $response 500 "Unable to update the monthly work schedules."
        continue
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    if ($updatedCount -gt 0) {
        $historyWarning = Invoke-PostCommitActionSafely -Description "Monthly schedules saved, but history logging failed" -Action {
            $employeeName = Get-EmployeeName $employeeCode
            $scheduleLabel = if ($workSchedule -eq "compressed") { "compressed" } else { "regular" }
            logHistory "Update" "Set <strong>$updatedCount</strong> unconfirmed entr$(if ($updatedCount -eq 1) { "y" } else { "ies" }) to <strong>$scheduleLabel schedule</strong> for <strong>$month</strong>." $employeeName -PublishChange:$false
        }
        if (-not [string]::IsNullOrWhiteSpace($historyWarning)) {
            [void]$postCommitWarnings.Add($historyWarning)
        }
        $syncWarning = Invoke-PostCommitActionSafely -Description "Monthly schedules saved, but cross-machine refresh publication failed" -Action {
            Publish-DataChange -Category "employee" -Resource $employeeCode | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($syncWarning)) {
            [void]$postCommitWarnings.Add($syncWarning)
        }
    }

    respondWithSuccess $response (([PSCustomObject]@{
        employeeCode          = $employeeCode
        month                 = $month
        workSchedule          = $workSchedule
        updatedCount          = $updatedCount
        alreadyConfirmedCount = $alreadyConfirmedCount
        unauthorizedCount     = $unauthorizedCount
        warnings              = @($postCommitWarnings.ToArray())
    }) | ConvertTo-Json -Depth 4)
    continue
}
