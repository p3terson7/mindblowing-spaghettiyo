$overtimeCompensationModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.OvertimeCompensation.psd1"
Import-Module -Name $overtimeCompensationModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name overtimeCompensationModuleManifest -ErrorAction SilentlyContinue

$snapshotCompensationGridModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath "../modules/Saphir.CompensationGrid.psd1"
Import-Module -Name $snapshotCompensationGridModuleManifest -Force -ErrorAction Stop | Out-Null
Remove-Variable -Name snapshotCompensationGridModuleManifest -ErrorAction SilentlyContinue

function ConvertTo-EntryCreditedMinutes {
    param($Entry)

    if ($null -eq $Entry -or $Entry.PSObject.Properties.Name -notcontains "overtime") {
        return $null
    }

    $parts = @(([string]$Entry.overtime).Trim().Split(":"))
    if ($parts.Count -lt 2) {
        return $null
    }

    $hours = 0
    $minutes = 0
    $seconds = 0
    if (-not [int]::TryParse([string]$parts[0], [ref]$hours) -or
        -not [int]::TryParse([string]$parts[1], [ref]$minutes) -or
        $hours -lt 0 -or $minutes -lt 0 -or $minutes -gt 59) {
        return $null
    }
    if ($parts.Count -ge 3 -and (-not [int]::TryParse([string]$parts[2], [ref]$seconds) -or $seconds -lt 0 -or $seconds -gt 59)) {
        return $null
    }

    $totalMinutes = ($hours * 60) + $minutes
    if ($seconds -ge 30) {
        $totalMinutes++
    }
    if (($totalMinutes % 15) -ne 0) {
        return $null
    }

    return $totalMinutes
}

function New-UnavailableEntryCompensationSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [AllowNull()]$Assignment,
        [AllowNull()]$SalaryBand,
        [Parameter(Mandatory = $true)][string]$SourceFingerprint,
        [Parameter(Mandatory = $true)][string]$CalculatedAtUtc
    )

    $contract = Saphir.OvertimeCompensation\Get-SaphirOvertimeMonetaryContract
    return [PSCustomObject][ordered]@{
        snapshotVersion                   = 1
        snapshotStatus                    = "unavailable"
        calculationVersion                = [string]$contract.calculationVersion
        estimateOnly                      = $true
        currency                          = [string]$contract.currency
        costBasis                         = [string]$contract.costBasis
        includesEmployerCosts             = [bool]$contract.includesEmployerCosts
        compensationAssignmentId          = if ($null -ne $Assignment) { [string]$Assignment.id } else { $null }
        salaryBandId                       = if ($null -ne $SalaryBand) { [string]$SalaryBand.id } else { $null }
        classification                    = if ($null -ne $Assignment) { [PSCustomObject][ordered]@{ group = [string]$Assignment.group; subGroup = [string]$Assignment.subGroup; level = [string]$Assignment.level } } else { $null }
        sourceFingerprint                  = $SourceFingerprint
        unavailableReason                 = $Reason
        calculatedAtUtc                   = $CalculatedAtUtc
    }
}

function Get-EntryCompensationSourceFingerprint {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [AllowNull()]$Assignment,
        [AllowNull()]$SalaryBand,
        [AllowNull()]$CreditedMinutes,
        [int]$PreviouslyCreditedMinutes = 0,
        [bool]$HolidayAdjacentToSecondRest = $false,
        [AllowNull()][string]$UnavailableReason
    )

    $values = @(
        "snapshot-v1",
        ([string]$Entry.entryId),
        ([string]$Entry.date),
        ([string]$Entry.overtime),
        ([string]$Entry.overtimeCode),
        ([string]$Entry.workSchedule),
        ([string]$Entry.paymentOption),
        $(if ($null -ne $Assignment) { [string]$Assignment.id } else { "" }),
        $(if ($null -ne $SalaryBand) { [string]$SalaryBand.id } else { "" }),
        $(if ($null -ne $SalaryBand) { [string]$SalaryBand.annualSalaryCents } else { "" }),
        $(if ($null -ne $CreditedMinutes) { [string]$CreditedMinutes } else { "" }),
        ([string]$PreviouslyCreditedMinutes),
        ([string][bool]$HolidayAdjacentToSecondRest),
        ([string]$UnavailableReason)
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($values -join [string][char]31))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant())
    }
    finally {
        $sha256.Dispose()
    }
}

function Set-EntryCompensationSnapshotIfChanged {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]$Snapshot
    )

    if ($Entry.PSObject.Properties.Name -contains "compensationSnapshot") {
        $existing = $Entry.compensationSnapshot
        if ($null -ne $existing -and
            $existing.PSObject.Properties.Name -contains "sourceFingerprint" -and
            [string]$existing.sourceFingerprint -eq [string]$Snapshot.sourceFingerprint -and
            [string]$existing.calculationVersion -eq [string]$Snapshot.calculationVersion -and
            [string]$existing.snapshotStatus -eq [string]$Snapshot.snapshotStatus) {
            return $false
        }
    }

    Set-EntryPropertyValue -Entry $Entry -Name "compensationSnapshot" -Value $Snapshot
    return $true
}

function Test-ApprovedEntryHolidayAdjacentToSecondRest {
    param(
        [Parameter(Mandatory = $true)][DateTime]$EntryDate,
        [Parameter(Mandatory = $true)]$WorkedDateCodes
    )

    foreach ($candidate in @($EntryDate.AddDays(-1), $EntryDate.AddDays(1))) {
        $key = $candidate.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
        if ($WorkedDateCodes.ContainsKey($key) -and $WorkedDateCodes[$key].ContainsKey("262")) {
            return $true
        }
    }
    return $false
}

function Set-ApprovedEntryCompensationSnapshots {
    <#
        Rebuilds the private monetary snapshots for approved overtime rows in
        one employee document. Callers run this while holding that employee
        file's writer lock, immediately before the atomic write.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Entries,
        [AllowNull()]$EmployeeUser,
        [AllowNull()][string]$CalculationTimeUtc
    )

    $calculatedAtUtc = if ([string]::IsNullOrWhiteSpace($CalculationTimeUtc)) { (Get-Date).ToUniversalTime().ToString("o") } else { [string]$CalculationTimeUtc }
    $user = $null
    $currentClassification = $null
    $assignmentLoadError = $null
    try {
        $user = if ($null -ne $EmployeeUser) { $EmployeeUser } else { Get-EmployeeUserByCode -EmployeeCode $EmployeeCode }
        $currentClassification = if ($null -ne $user) { Get-EmployeeClassificationFromUserRecord -UserRecord $user } else { $null }
    }
    catch {
        # Compensation metadata must never turn a valid operational approval
        # into a failed approval. Persist a stable unavailable reason instead.
        $assignmentLoadError = $_
    }
    $salaryGrid = $null
    $salaryGridError = $null
    try {
        $salaryGrid = Get-CompensationGrid
    }
    catch {
        $salaryGridError = $_
    }

    $approvedEntries = New-Object System.Collections.ArrayList
    $workedDateCodes = @{}
    foreach ($entry in @($Entries)) {
        $entryType = if ($entry.PSObject.Properties.Name -contains "entryType") { ([string]$entry.entryType).Trim().ToLowerInvariant() } else { "overtime" }
        $status = ([string]$entry.status).Trim().ToLowerInvariant()
        if ($entryType -ne "diverse" -and $status -eq "approved") {
            [void]$approvedEntries.Add($entry)
            $dateKey = ([string]$entry.date).Trim()
            $overtimeCode = ([string]$entry.overtimeCode).Trim()
            if (-not [string]::IsNullOrWhiteSpace($dateKey)) {
                if (-not $workedDateCodes.ContainsKey($dateKey)) {
                    $workedDateCodes[$dateKey] = @{}
                }
                $workedDateCodes[$dateKey][$overtimeCode] = $true
            }
        }
        elseif ($entry.PSObject.Properties.Name -contains "compensationSnapshot") {
            $entry.PSObject.Properties.Remove("compensationSnapshot")
        }
    }

    $creditedMinutesByDateAndCategory = @{}
    $sortedEntries = @($approvedEntries.ToArray() | Sort-Object date, punchIn, entryId)
    foreach ($entry in $sortedEntries) {
        $entryDate = [DateTime]::MinValue
        $dateIsValid = [DateTime]::TryParseExact(
            ([string]$entry.date).Trim(),
            "yyyy-MM-dd",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$entryDate
        )
        if (-not $dateIsValid) {
            $reason = "entry-date-invalid"
            $fingerprint = Get-EntryCompensationSourceFingerprint -Entry $entry -Assignment $null -SalaryBand $null -CreditedMinutes $null -UnavailableReason $reason
            Set-EntryCompensationSnapshotIfChanged -Entry $entry -Snapshot (New-UnavailableEntryCompensationSnapshot -Reason $reason -Assignment $null -SalaryBand $null -SourceFingerprint $fingerprint -CalculatedAtUtc $calculatedAtUtc) | Out-Null
            continue
        }

        $creditedMinutes = ConvertTo-EntryCreditedMinutes -Entry $entry
        if ($null -eq $creditedMinutes) {
            $reason = "credited-duration-invalid"
            $fingerprint = Get-EntryCompensationSourceFingerprint -Entry $entry -Assignment $null -SalaryBand $null -CreditedMinutes $null -UnavailableReason $reason
            Set-EntryCompensationSnapshotIfChanged -Entry $entry -Snapshot (New-UnavailableEntryCompensationSnapshot -Reason $reason -Assignment $null -SalaryBand $null -SourceFingerprint $fingerprint -CalculatedAtUtc $calculatedAtUtc) | Out-Null
            continue
        }

        $existingSnapshot = if ($entry.PSObject.Properties.Name -contains "compensationSnapshot") { $entry.compensationSnapshot } else { $null }
        $hasCapturedSalary = ($null -ne $existingSnapshot -and
            [string]$existingSnapshot.snapshotStatus -eq "final" -and
            $existingSnapshot.PSObject.Properties.Name -contains "annualSalaryCents" -and
            [long]$existingSnapshot.annualSalaryCents -gt 0 -and
            $null -ne $existingSnapshot.classification)

        if ($null -ne $assignmentLoadError -and -not $hasCapturedSalary) {
            $reason = "employee-classification-invalid"
            $fingerprint = Get-EntryCompensationSourceFingerprint -Entry $entry -Assignment $null -SalaryBand $null -CreditedMinutes $creditedMinutes -UnavailableReason $reason
            Set-EntryCompensationSnapshotIfChanged -Entry $entry -Snapshot (New-UnavailableEntryCompensationSnapshot -Reason $reason -Assignment $null -SalaryBand $null -SourceFingerprint $fingerprint -CalculatedAtUtc $calculatedAtUtc) | Out-Null
            continue
        }

        $classification = if ($hasCapturedSalary) { $existingSnapshot.classification } else { $currentClassification }
        $assignment = if ($null -ne $classification) {
            [PSCustomObject]@{
                id       = if ($hasCapturedSalary) { [string]$existingSnapshot.compensationAssignmentId } else { "profile" }
                group    = [string]$classification.group
                subGroup = [string]$classification.subGroup
                level    = [string]$classification.level
            }
        } else { $null }
        if ($null -eq $assignment) {
            $reason = "employee-classification-missing"
            $fingerprint = Get-EntryCompensationSourceFingerprint -Entry $entry -Assignment $null -SalaryBand $null -CreditedMinutes $creditedMinutes -UnavailableReason $reason
            Set-EntryCompensationSnapshotIfChanged -Entry $entry -Snapshot (New-UnavailableEntryCompensationSnapshot -Reason $reason -Assignment $null -SalaryBand $null -SourceFingerprint $fingerprint -CalculatedAtUtc $calculatedAtUtc) | Out-Null
            continue
        }
        if ($null -ne $salaryGridError -and -not $hasCapturedSalary) {
            $reason = "salary-grid-unavailable"
            $fingerprint = Get-EntryCompensationSourceFingerprint -Entry $entry -Assignment $assignment -SalaryBand $null -CreditedMinutes $creditedMinutes -UnavailableReason $reason
            Set-EntryCompensationSnapshotIfChanged -Entry $entry -Snapshot (New-UnavailableEntryCompensationSnapshot -Reason $reason -Assignment $assignment -SalaryBand $null -SourceFingerprint $fingerprint -CalculatedAtUtc $calculatedAtUtc) | Out-Null
            continue
        }

        $salaryBand = if ($hasCapturedSalary) {
            # A promotion or salary-grid adjustment must not reprice approved
            # history when another entry is approved or edited. Duration and
            # daily threshold changes still use this entry's captured salary.
            [PSCustomObject]@{ id = [string]$existingSnapshot.salaryBandId; annualSalaryCents = [long]$existingSnapshot.annualSalaryCents }
        } else {
            Saphir.CompensationGrid\Resolve-CompensationSalaryBand -SalaryGrid $salaryGrid -Group ([string]$assignment.group) -SubGroup ([string]$assignment.subGroup) -Level ([string]$assignment.level) -AsOfDate $entryDate
        }
        if ($null -eq $salaryBand) {
            $reason = "salary-band-missing"
            $fingerprint = Get-EntryCompensationSourceFingerprint -Entry $entry -Assignment $assignment -SalaryBand $null -CreditedMinutes $creditedMinutes -UnavailableReason $reason
            Set-EntryCompensationSnapshotIfChanged -Entry $entry -Snapshot (New-UnavailableEntryCompensationSnapshot -Reason $reason -Assignment $assignment -SalaryBand $null -SourceFingerprint $fingerprint -CalculatedAtUtc $calculatedAtUtc) | Out-Null
            continue
        }

        $workSchedule = if ($entry.PSObject.Properties.Name -contains "workSchedule") { ([string]$entry.workSchedule).Trim().ToLowerInvariant() } else { "unconfirmed" }
        if (@("regular", "compressed") -notcontains $workSchedule) {
            $workSchedule = "unconfirmed"
        }
        $paymentOption = if (([string]$entry.paymentOption).Trim().ToLowerInvariant() -eq "leave") { "leave" } else { "cash" }
        $category = Saphir.OvertimeCompensation\Get-SaphirOvertimeCategory -OvertimeCode ([string]$entry.overtimeCode)
        $usageKey = "{0}|{1}" -f $entryDate.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture), $category
        $previouslyCreditedMinutes = if ($creditedMinutesByDateAndCategory.ContainsKey($usageKey)) { [int]$creditedMinutesByDateAndCategory[$usageKey] } else { 0 }
        $holidayAdjacent = ($category -eq "holiday" -and (Test-ApprovedEntryHolidayAdjacentToSecondRest -EntryDate $entryDate -WorkedDateCodes $workedDateCodes))
        $estimate = Saphir.OvertimeCompensation\Get-SaphirOvertimeCostEstimate `
            -AnnualSalaryCents ([long]$salaryBand.annualSalaryCents) `
            -OvertimeCode ([string]$entry.overtimeCode) `
            -WorkSchedule $workSchedule `
            -CreditedMinutes ([int]$creditedMinutes) `
            -PreviouslyCreditedMinutes $previouslyCreditedMinutes `
            -PaymentOption $paymentOption `
            -HolidayAdjacentToSecondRest:$holidayAdjacent

        $sourceFingerprint = Get-EntryCompensationSourceFingerprint `
            -Entry $entry `
            -Assignment $assignment `
            -SalaryBand $salaryBand `
            -CreditedMinutes $creditedMinutes `
            -PreviouslyCreditedMinutes $previouslyCreditedMinutes `
            -HolidayAdjacentToSecondRest:$holidayAdjacent `
            -UnavailableReason ([string]$estimate.unavailableReason)

        $snapshot = [PSCustomObject][ordered]@{
            snapshotVersion                   = 1
            snapshotStatus                    = if ([string]$estimate.calculationStatus -eq "unavailable") { "unavailable" } else { "final" }
            calculationVersion                = [string]$estimate.calculationVersion
            estimateOnly                      = [bool]$estimate.estimateOnly
            currency                          = [string]$estimate.currency
            costBasis                         = [string]$estimate.costBasis
            includesEmployerCosts             = [bool]$estimate.includesEmployerCosts
            compensationAssignmentId          = [string]$assignment.id
            salaryBandId                       = [string]$salaryBand.id
            classification                    = [PSCustomObject][ordered]@{ group = [string]$assignment.group; subGroup = [string]$assignment.subGroup; level = [string]$assignment.level }
            sourceFingerprint                  = $sourceFingerprint
            annualSalaryCents                  = [long]$salaryBand.annualSalaryCents
            annualHoursDivisor                 = [decimal]$estimate.annualHoursDivisor
            hourlyRateCents                    = $estimate.hourlyRateCents
            overtimeCode                      = [string]$estimate.overtimeCode
            overtimeCategory                  = [string]$estimate.overtimeCategory
            workSchedule                      = [string]$estimate.workSchedule
            paymentOption                     = [string]$estimate.paymentOption
            creditedMinutes                   = [int]$estimate.creditedMinutes
            previouslyCreditedMinutes         = [int]$estimate.previouslyCreditedMinutes
            holidayAdjacentToSecondRest        = [bool]$holidayAdjacent
            segments                          = @($estimate.segments)
            totalAmountCents                  = $estimate.totalAmountCents
            cashAmountCents                   = $estimate.cashAmountCents
            compensatoryLeaveValueCents       = $estimate.compensatoryLeaveValueCents
            unavailableReason                 = $estimate.unavailableReason
            calculatedAtUtc                   = $calculatedAtUtc
        }
        Set-EntryCompensationSnapshotIfChanged -Entry $entry -Snapshot $snapshot | Out-Null
        $creditedMinutesByDateAndCategory[$usageKey] = $previouslyCreditedMinutes + [int]$creditedMinutes
    }

    return $Entries
}

function Get-EmployeeCompensationReadEstimates {
    <#
        Legacy approvals can be displayed without a write/backfill on a shared
        drive. Calculate on private copies of the whole employee document (not
        the filtered project/date slice, which would reset daily thresholds).
        Captured final snapshots remain authoritative and are never replaced.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$EmployeeCode,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Entries
    )

    $sourceEntries = @($Entries)
    $needsEstimate = @($sourceEntries | Where-Object {
        [string]$_.status -eq "approved" -and [string]$_.entryType -ne "diverse" -and
        ($_.PSObject.Properties.Name -notcontains "compensationSnapshot" -or [string]$_.compensationSnapshot.snapshotStatus -ne "final")
    }).Count -gt 0
    if (-not $needsEstimate) { return $sourceEntries }

    $copies = @($sourceEntries | ForEach-Object {
        $properties = [ordered]@{}
        foreach ($property in $_.PSObject.Properties) { $properties[$property.Name] = $property.Value }
        [PSCustomObject]$properties
    })
    Set-ApprovedEntryCompensationSnapshots -EmployeeCode $EmployeeCode -Entries $copies | Out-Null
    for ($index = 0; $index -lt $sourceEntries.Count; $index++) {
        $original = $sourceEntries[$index]
        if ($original.PSObject.Properties.Name -contains "compensationSnapshot" -and [string]$original.compensationSnapshot.snapshotStatus -eq "final") {
            Set-EntryPropertyValue -Entry $copies[$index] -Name "compensationSnapshot" -Value $original.compensationSnapshot
        }
    }
    return $copies
}

function Update-EmployeeApprovedCompensationSnapshots {
    <#
        Reconciles historical approved entries after a super admin changes an
        employee's compensation classification. The employee profile remains
        the canonical commit; a failure here is reported as a post-commit
        warning by the route instead of making the saved profile look failed.
    #>
    param([Parameter(Mandatory = $true)][string]$EmployeeCode)

    $dataFile = Get-EmployeeDataFilePath -EmployeeCode $EmployeeCode
    if (-not (Test-SaphirFileExists -Path $dataFile)) {
        return [PSCustomObject]@{ changed = $false; approvedEntryCount = 0 }
    }

    $lockHandle = Acquire-ResourceLock -ResourcePath $dataFile
    try {
        $entries = @(Read-JsonArrayFile -Path $dataFile)
        $before = ConvertTo-Json -InputObject @($entries) -Depth 8 -Compress
        Set-ApprovedEntryCompensationSnapshots -EmployeeCode $EmployeeCode -Entries $entries | Out-Null
        $after = ConvertTo-Json -InputObject @($entries) -Depth 8 -Compress
        $changed = ($before -ne $after)
        if ($changed) {
            Write-JsonArrayAtomic -Path $dataFile -Items $entries -Depth 8
            if (Get-Command -Name Clear-EmployeeEntryCacheForCode -ErrorAction SilentlyContinue) {
                Clear-EmployeeEntryCacheForCode -EmployeeCode $EmployeeCode | Out-Null
            }
        }

        return [PSCustomObject]@{
            changed            = $changed
            approvedEntryCount = @($entries | Where-Object {
                $entryType = if ($_.PSObject.Properties.Name -contains "entryType") { ([string]$_.entryType).Trim().ToLowerInvariant() } else { "overtime" }
                $entryType -ne "diverse" -and ([string]$_.status).Trim().ToLowerInvariant() -eq "approved"
            }).Count
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }
}
