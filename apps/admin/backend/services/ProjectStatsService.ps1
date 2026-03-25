function Get-ProjectStatistics {
    param (
        [string]$startDate,
        [string]$endDate
    )
    
    $startDt = $null; $endDt = $null
    if ($startDate) { 
        try { 
            $startDt = [DateTime]::ParseExact($startDate, "yyyy-MM-dd", $null) 
        }
        catch { }
    }
    if ($endDate) { 
        try { 
            $endDt = [DateTime]::ParseExact($endDate, "yyyy-MM-dd", $null) 
        }
        catch { }
    }
    
    $stats = @{}
    $employeeFiles = Get-ChildItem -Path $sharedFolder -Filter "*_data.json"
    foreach ($file in $employeeFiles) {
        $entries = Read-JsonArrayFile -Path $file.FullName
        foreach ($entry in $entries) {
            if ([string]::IsNullOrWhiteSpace($entry.projectCode)) { continue }

            try {
                $entryDate = [DateTime]::ParseExact($entry.date, "yyyy-MM-dd", $null)
            }
            catch {
                continue
            }

            if ($startDt -and $entryDate -lt $startDt) { continue }
            if ($endDt -and $entryDate -gt $endDt) { continue }

            $proj = $entry.projectCode

            try {
                $ts = [TimeSpan]::Parse($entry.overtime)
            }
            catch {
                $ts = [TimeSpan]::Zero
            }
            $seconds = $ts.TotalSeconds

            if (-not $stats.ContainsKey($proj)) {
                $stats[$proj] = [PSCustomObject]@{
                    totalSeconds = 0
                    entryCount   = 0
                    breakdown    = @{}
                    entries      = @()
                }
            }
            $stats[$proj].totalSeconds += $seconds
            $stats[$proj].entryCount++
            $stats[$proj].entries += $entry

            $emp = $entry.name
            if (-not $stats[$proj].breakdown.ContainsKey($emp)) {
                $stats[$proj].breakdown[$emp] = @{
                    totalSeconds = 0
                    entryCount   = 0
                    entries      = @()
                }
            }
            $stats[$proj].breakdown[$emp].totalSeconds += $seconds
            $stats[$proj].breakdown[$emp].entryCount++
            $stats[$proj].breakdown[$emp].entries += [PSCustomObject]@{
                date     = $entry.date
                punchIn  = $entry.punchIn
                punchOut = $entry.punchOut
            }
        }
    }
    return $stats
}
