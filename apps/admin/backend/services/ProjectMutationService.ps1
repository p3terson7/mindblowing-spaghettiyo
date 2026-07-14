function Test-ProjectCodeFormat {
    param([AllowNull()][string]$ProjectCode)

    $candidate = ([string]$ProjectCode).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.Length -gt 64) {
        return $false
    }

    return [regex]::IsMatch($candidate, '^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$')
}

function Read-ProjectEmployeeEntriesStrict {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq "null") {
        return @()
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $fileName = [System.IO.Path]::GetFileName($Path)
        throw "Cannot safely modify projects because employee data file '$fileName' is not valid JSON."
    }

    if ($null -eq $parsed) {
        return @()
    }
    if (-not ($parsed -is [System.Collections.IEnumerable]) -or ($parsed -is [string])) {
        return @($parsed)
    }

    return @($parsed)
}

function Get-ProjectEntryReferenceSummary {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectCode,
        [string]$DataFolderPath = $sharedFolder
    )

    $normalizedCode = ([string]$ProjectCode).Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedCode)) {
        throw "Project code is required when checking project references."
    }

    $referenceCount = 0
    $employeeCodes = New-Object System.Collections.ArrayList
    $dataFiles = @()
    if (Test-Path -LiteralPath $DataFolderPath -PathType Container) {
        $dataFiles = @(
            Get-ChildItem -LiteralPath $DataFolderPath -Filter "*_data.json" -File |
                Sort-Object FullName
        )
    }

    foreach ($dataFile in $dataFiles) {
        $fileReferenceCount = 0
        foreach ($entry in @(Read-ProjectEmployeeEntriesStrict -Path $dataFile.FullName)) {
            if ($null -eq $entry -or -not ($entry.PSObject.Properties.Name -contains "projectCode")) {
                continue
            }
            if (([string]$entry.projectCode).Trim() -eq $normalizedCode) {
                $referenceCount++
                $fileReferenceCount++
            }
        }

        if ($fileReferenceCount -gt 0) {
            $employeeCode = [System.IO.Path]::GetFileNameWithoutExtension($dataFile.Name) -replace "_data$", ""
            [void]$employeeCodes.Add($employeeCode)
        }
    }

    return [PSCustomObject]@{
        projectCode     = $normalizedCode
        referenceCount  = $referenceCount
        employeeCodes   = @($employeeCodes.ToArray())
        dataFilesScanned = $dataFiles.Count
    }
}
