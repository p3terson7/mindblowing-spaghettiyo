#requires -Version 5.1
<#
.SYNOPSIS
Preview or safely backfill missing approved-entry amounts. Never runs at startup.
.DESCRIPTION
Uses current classifications and the existing salary/rate rules. Preview is read-only.
Apply requires all SAPHIR backends to be stopped, verified backups, unchanged inputs,
and filesystem support for atomic File.Replace (no delete/move fallback).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DataFolder,
    [string]$ApplicationRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) "app"),
    [switch]$Apply,
    [switch]$AppStopped
)
$ErrorActionPreference = "Stop"
if ($Apply -and -not $AppStopped) { throw "Stop SAPHIR on ALL computers, then supply -Apply -AppStopped. Preview needs neither switch." }
$dataRoot = (Resolve-Path -LiteralPath $DataFolder -ErrorAction Stop).ProviderPath
if (-not [IO.Directory]::Exists($dataRoot)) { throw "DataFolder must be an existing DATA directory." }
$backendRoot = Join-Path $ApplicationRoot "backend"
$script:SaphirPerformanceEnabled = $false
$script:SaphirPerformanceRecord = $null
$script:sharedFolder = $dataRoot
$script:lockFolder = Join-Path $dataRoot ".locks"
$script:compensationGridFile = Join-Path $dataRoot "compensation-grid.json"
# AuthService normally initializes storage when imported by the server. This
# maintenance script must never initialize users/sessions, even in preview.
$script:AuthStorageEnsured = $true
$script:TextFileCache = @{}; $script:BinaryFileCache = @{}; $script:FileMetadataCache = @{}
$script:HeldResourceLocks = @{}; $script:PreparedLockFolderPath = ''
$script:CompensationGridRuntimeCache = $null; $script:CompensationSalaryBandIndexCache = $null
foreach ($source in @("lib/FileStore.ps1", "services/AuthService.ps1", "services/EntryService.ps1", "services/CompensationGridService.ps1", "services/OvertimeCostSnapshotService.ps1")) {
    . (Join-Path $backendRoot $source)
}

function Get-BackfillHash([byte[]]$Bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace("-", "").ToLowerInvariant() }
    finally { $hash.Dispose() }
}

# Only snapshot values are serialized. Splicing their JSON into the original
# text preserves every other byte of every entry, including unknown fields,
# date strings, large numbers, escaped text and deeply nested custom data.
function Get-BackfillValueEnd([string]$Text, [int]$Start) {
    $quoted = $false; $escaped = $false; $depth = 0
    for ($cursor = $Start; $cursor -lt $Text.Length; $cursor++) {
        $character = $Text[$cursor]
        if ($quoted) {
            if ($escaped) { $escaped = $false }
            elseif ($character -eq '\') { $escaped = $true }
            elseif ($character -eq '"') { $quoted = $false; if ($depth -eq 0) { return ($cursor + 1) } }
        }
        elseif ($character -eq '"') { $quoted = $true }
        elseif ($character -eq '{' -or $character -eq '[') { $depth++ }
        elseif ($character -eq '}' -or $character -eq ']') {
            if ($depth -eq 0) { return $cursor }
            $depth--; if ($depth -eq 0) { return ($cursor + 1) }
        }
        elseif ($depth -eq 0 -and ($character -eq ',' -or [char]::IsWhiteSpace($character))) { return $cursor }
    }
    return $cursor
}

function Get-BackfillMembers([string]$Text, [int]$Start, [int]$End) {
    $cursor = $Start + 1; $names = @{}
    while ($cursor -lt ($End - 1)) {
        while ($cursor -lt ($End - 1) -and [char]::IsWhiteSpace($Text[$cursor])) { $cursor++ }
        if ($cursor -ge ($End - 1)) { break }
        if ($Text[$cursor] -ne '"') { throw "Unsupported JSON object syntax; no data was changed." }
        $keyEnd = Get-BackfillValueEnd $Text $cursor
        $name = [string](ConvertFrom-Json -InputObject ('[' + $Text.Substring($cursor, $keyEnd - $cursor) + ']'))
        if ($names.ContainsKey($name)) { throw "Duplicate or case-ambiguous JSON property; no data was changed." }
        $names[$name] = $true; $cursor = $keyEnd
        while ([char]::IsWhiteSpace($Text[$cursor])) { $cursor++ }
        if ($Text[$cursor] -ne ':') { throw "Invalid JSON property separator." }
        $cursor++
        while ([char]::IsWhiteSpace($Text[$cursor])) { $cursor++ }
        $valueEnd = Get-BackfillValueEnd $Text $cursor
        [PSCustomObject]@{ name = $name; start = $cursor; end = $valueEnd }
        $cursor = $valueEnd
        while ($cursor -lt ($End - 1) -and [char]::IsWhiteSpace($Text[$cursor])) { $cursor++ }
        if ($cursor -lt ($End - 1)) {
            if ($Text[$cursor] -ne ',') { throw "Invalid JSON property delimiter." }
            $cursor++
        }
    }
}

function ConvertTo-BackfillDocument([byte[]]$Bytes) {
    $text = ([Text.UTF8Encoding]::new($false, $true)).GetString($Bytes).TrimStart([char]0xfeff)
    $trimmed = $text.Trim()
    if (-not $trimmed.StartsWith('[') -or -not $trimmed.EndsWith(']')) { throw "Employee files must contain JSON arrays, not null, empty text or objects." }
    ConvertFrom-Json -InputObject $text -ErrorAction Stop | Out-Null
    $objects = New-Object Collections.ArrayList
    $cursor = $text.IndexOf('[') + 1
    while ($cursor -lt $text.Length) {
        while ([char]::IsWhiteSpace($text[$cursor])) { $cursor++ }
        if ($text[$cursor] -eq ']') { break }
        if ($text[$cursor] -ne '{') { throw "Every employee array element must be an object." }
        $end = Get-BackfillValueEnd $text $cursor
        $members = @(Get-BackfillMembers $text $cursor $end)
        [void]$objects.Add([PSCustomObject]@{ start = $cursor; end = $end; members = $members; entry = (ConvertFrom-Json -InputObject $text.Substring($cursor, $end - $cursor)) })
        $cursor = $end
        while ([char]::IsWhiteSpace($text[$cursor])) { $cursor++ }
        if ($text[$cursor] -eq ']') { break }
        if ($text[$cursor] -ne ',') { throw "Invalid employee array delimiter." }
        $cursor++
    }
    return [PSCustomObject]@{ text = $text; objects = @($objects.ToArray()) }
}

function Write-BackfillNewFile([string]$Path, [byte[]]$Bytes) {
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ((Get-BackfillHash ([IO.File]::ReadAllBytes($Path))) -cne (Get-BackfillHash $Bytes)) { throw "Backup/staging verification failed: $Path" }
}

function Assert-BackfillSourcesUnchanged($Plan, $Inputs) {
    foreach ($sourceInput in $Inputs.Values) {
        if ((Get-BackfillHash ([IO.File]::ReadAllBytes($sourceInput.path))) -cne $sourceInput.hash) { throw "Salary inputs changed after preflight; migration stopped. Rerun preview." }
    }
    if ((Get-BackfillHash ([IO.File]::ReadAllBytes($Plan.path))) -cne $Plan.hash) { throw "Employee file changed after preflight; migration stopped: $($Plan.name)" }
}

$inputs = @{}
foreach ($name in @("users.json", "compensation-grid.json")) {
    $path = Join-Path $dataRoot $name
    $bytes = [IO.File]::ReadAllBytes($path)
    $inputs[$name] = [PSCustomObject]@{ path = $path; bytes = $bytes; hash = (Get-BackfillHash $bytes) }
}
$usersText = ([Text.UTF8Encoding]::new($false, $true)).GetString($inputs['users.json'].bytes).TrimStart([char]0xfeff)
if (-not $usersText.Trim().StartsWith('[')) { throw "users.json must be an array." }
$users = @(ConvertFrom-Json -InputObject $usersText -ErrorAction Stop)
$userByCode = @{}
foreach ($user in $users) {
    $code = Get-UserEmployeeCodeValue -UserRecord $user
    if (-not $code) { continue }
    if ($userByCode.ContainsKey($code)) { throw "Duplicate employee code in users.json; resolve it before migrating." }
    $userByCode[$code] = $user
}
# Validate the grid before any backup or mutation. No defaults are created.
Get-CompensationGrid | Out-Null
$plans = New-Object Collections.ArrayList
$issues = New-Object Collections.ArrayList
$calculatedAt = [DateTime]::UtcNow.ToString('o')
foreach ($file in @(Get-ChildItem -LiteralPath $dataRoot -File | Where-Object { $_.Name -match '^\d+_data\.json$' } | Sort-Object Name)) {
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked employee files are not supported: $($file.Name)" }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    try { $document = ConvertTo-BackfillDocument $bytes }
    catch { throw "Preflight failed for $($file.Name): $($_.Exception.Message) No employee files have been written." }
    $entries = @($document.objects | ForEach-Object { $_.entry.PSObject.Copy() })
    $code = $file.BaseName -replace '_data$', ''
    $candidateIndexes = @(for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = $entries[$index]
        if (([string]$entry.status).Trim().ToLowerInvariant() -eq 'approved' -and
            ([string]$entry.entryType).Trim().ToLowerInvariant() -ne 'diverse' -and
            [string]$entry.compensationSnapshot.snapshotStatus -ne 'final') { $index }
    })
    if ($candidateIndexes.Count -gt 0 -and $userByCode.ContainsKey($code)) {
        Set-ApprovedEntryCompensationSnapshots -EmployeeCode $code -EmployeeUser $userByCode[$code] -Entries $entries -MissingSnapshotsOnly -CalculationTimeUtc $calculatedAt | Out-Null
    }
    $edits = New-Object Collections.ArrayList
    $fileAmounts = 0; $fileUnavailable = 0
    foreach ($index in $candidateIndexes) {
        $snapshot = $entries[$index].compensationSnapshot
        if (-not $userByCode.ContainsKey($code) -or [string]$snapshot.snapshotStatus -ne 'final') {
            $reason = if (-not $userByCode.ContainsKey($code)) { 'employee-user-missing' } else { [string]$snapshot.unavailableReason }
            [void]$issues.Add([PSCustomObject]@{ file = $file.Name; entryIndex = $index; entryId = [string]$entries[$index].entryId; reason = $reason })
            if (-not $userByCode.ContainsKey($code)) {
                $fingerprint = Get-EntryCompensationSourceFingerprint -Entry $entries[$index] -Assignment $null -SalaryBand $null -CreditedMinutes (ConvertTo-EntryCreditedMinutes $entries[$index]) -UnavailableReason $reason
                $snapshot = New-UnavailableEntryCompensationSnapshot -Reason $reason -Assignment $null -SalaryBand $null -SourceFingerprint $fingerprint -CalculatedAtUtc $calculatedAt
            }
        }
        $object = $document.objects[$index]
        $prior = $object.entry.compensationSnapshot
        # A stable N/A is a persisted result too. Do not rewrite it on reruns.
        if ($null -ne $prior -and $prior.sourceFingerprint -and
            [string]$prior.sourceFingerprint -ceq [string]$snapshot.sourceFingerprint -and
            [string]$prior.calculationVersion -ceq [string]$snapshot.calculationVersion -and
            [string]$prior.snapshotStatus -ceq [string]$snapshot.snapshotStatus) { continue }
        $existing = @($object.members | Where-Object { $_.name -eq 'compensationSnapshot' })
        $json = ConvertTo-Json -InputObject $snapshot -Depth 100 -Compress
        if ($existing.Count -eq 1) { $start = $existing[0].start; $end = $existing[0].end; $replacement = $json }
        else {
            $start = $object.end - 1; $end = $start
            $prefix = if ($object.members.Count -gt 0) { ',' } else { '' }
            $replacement = $prefix + '"compensationSnapshot":' + $json
        }
        [void]$edits.Add([PSCustomObject]@{ start = $start; end = $end; text = $replacement })
        if ([string]$snapshot.snapshotStatus -eq 'final') { $fileAmounts++ } else { $fileUnavailable++ }
    }
    $updated = $document.text
    foreach ($edit in @($edits | Sort-Object start -Descending)) { $updated = $updated.Remove($edit.start, $edit.end - $edit.start).Insert($edit.start, $edit.text) }
    $updatedBytes = ([Text.UTF8Encoding]::new($false)).GetBytes($updated)
    $verified = ConvertTo-BackfillDocument $updatedBytes
    if ($verified.objects.Count -ne $document.objects.Count) { throw "Entry-count verification failed: $($file.Name)" }
    [void]$plans.Add([PSCustomObject]@{ path = $file.FullName; name = $file.Name; original = $bytes; hash = (Get-BackfillHash $bytes); updated = $updatedBytes; snapshotCount = $edits.Count; amountCount = $fileAmounts; unavailableCount = $fileUnavailable; entryCount = $entries.Count })
}
$changed = @($plans | Where-Object { $_.snapshotCount -gt 0 })
$amountCount = 0; $unavailableCount = 0
foreach ($plan in $changed) { $amountCount += $plan.amountCount; $unavailableCount += $plan.unavailableCount }
$backupFolder = $null
if ($Apply -and $changed.Count -gt 0) {
    $migrationLock = Acquire-ResourceLock -ResourcePath (Join-Path $dataRoot '.compensation-backfill') -TimeoutMs 1000
    try {
        $backupParent = Join-Path $dataRoot '.saphir-backups'
        if ([IO.Directory]::Exists($backupParent) -and ((Get-Item -LiteralPath $backupParent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Backup directory must not be a link." }
        $backupFolder = Join-Path $backupParent ('compensation-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($backupFolder) | Out-Null
        Write-Host "Backup: $backupFolder"
        # Back up ALL enumerated employee files and both calculation inputs
        # before the first commit. Existing backups are never overwritten.
        foreach ($sourceInput in $inputs.Values) { Write-BackfillNewFile (Join-Path $backupFolder ([IO.Path]::GetFileName($sourceInput.path))) $sourceInput.bytes }
        foreach ($plan in $plans) { Write-BackfillNewFile (Join-Path $backupFolder $plan.name) $plan.original }
        $manifest = [PSCustomObject]@{ version = 1; createdAtUtc = $calculatedAt; inputs = @($inputs.Values | ForEach-Object { @{ name = [IO.Path]::GetFileName($_.path); sha256 = $_.hash } }); files = @($plans | ForEach-Object { @{ name = $_.name; sha256 = $_.hash; entries = $_.entryCount; amountsToAdd = $_.amountCount; unavailableToSave = $_.unavailableCount } }); issues = @($issues.ToArray()) }
        Write-BackfillNewFile (Join-Path $backupFolder 'manifest.json') ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $manifest -Depth 12)))
        foreach ($plan in $changed) {
            $lock = Acquire-ResourceLock -ResourcePath $plan.path -TimeoutMs 1000
            try {
                Assert-BackfillSourcesUnchanged $plan $inputs
                $stage = $plan.path + '.compensation-' + [Guid]::NewGuid().ToString('N') + '.tmp'
                Write-BackfillNewFile $stage $plan.updated
                Assert-BackfillSourcesUnchanged $plan $inputs
                # Fail closed if SMB cannot atomically replace a file. Never
                # delete the destination or fall back to an overwrite/copy.
                try { [IO.File]::Replace($stage, $plan.path, [NullString]::Value) }
                catch {
                    if ((Get-BackfillHash ([IO.File]::ReadAllBytes($plan.path))) -cne (Get-BackfillHash $plan.updated)) { throw }
                }
                if ((Get-BackfillHash ([IO.File]::ReadAllBytes($plan.path))) -cne (Get-BackfillHash $plan.updated)) { throw "Post-write verification failed. Stop and inspect the backup; no automatic restore was attempted." }
                Write-BackfillNewFile (Join-Path $backupFolder ($plan.name + '.completed.json')) ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject @{ sha256 = (Get-BackfillHash $plan.updated); amountsAdded = $plan.amountCount })))
            } finally { Release-ResourceLock $lock }
        }
    }
    catch { throw "Migration stopped: $($_.Exception.Message) Run directory: $backupFolder. Verify backup manifest/hashes before any restore; backup creation may itself have failed. Rerunning skips saved amounts. Staging files are retained for inspection." }
    finally { Release-ResourceLock $migrationLock }
}
$mode = if ($Apply) { 'applied' } else { 'preview' }
Write-Host "$mode : $amountCount amounts and $unavailableCount N/A results in $($changed.Count) files; $($issues.Count) entries need attention."
if ($issues.Count -gt 0) {
    Write-Warning "Some entries have an N/A amount until their missing information is corrected:"
    foreach ($issue in $issues) { Write-Warning ("{0}, entry index {1}: {2}" -f $issue.file, $issue.entryIndex, $issue.reason) }
}
[PSCustomObject]@{ mode = $mode; employeeFiles = $plans.Count; changedFiles = $changed.Count; amounts = $amountCount; unavailable = $unavailableCount; backupFolder = $backupFolder; issues = @($issues.ToArray()) }
