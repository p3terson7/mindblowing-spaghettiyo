# Helper function to emulate the null-coalescing operator
function Get-EmployeeNameMap {
    if (!(Test-Path -Path $mappingFile)) {
        @{} | ConvertTo-Json -Depth 3 | Set-Content -Path $mappingFile -Encoding UTF8
    }

    try {
        $map = Get-Content -Path $mappingFile -Raw | ConvertFrom-Json
        if ($null -eq $map) {
            return @{}
        }
        return $map
    }
    catch {
        return @{}
    }
}

function Get-EmployeeName($code) {
    $employeeNames = Get-EmployeeNameMap
    if ($employeeNames -and ($employeeNames.PSObject.Properties.Name -contains $code)) {
        return $employeeNames.$code
    }
    return $code
}

function Get-Projects {
    if (!(Test-Path -Path $projectsFile)) {
        @() | ConvertTo-Json -Depth 3 | Set-Content -Path $projectsFile -Encoding UTF8
    }

    try {
        $projects = Get-Content -Path $projectsFile -Raw | ConvertFrom-Json
        if ($null -eq $projects) {
            return @()
        }
        if (-not ($projects -is [System.Collections.IEnumerable]) -or ($projects -is [string])) {
            return @($projects)
        }
        return $projects
    }
    catch {
        return @()
    }
}

function Get-OvertimeCodes {
    if (!(Test-Path -Path $overtimeCodesFile)) {
        @() | ConvertTo-Json -Depth 3 | Set-Content -Path $overtimeCodesFile -Encoding UTF8
    }

    try {
        $overtimeCodes = Get-Content -Path $overtimeCodesFile -Raw | ConvertFrom-Json
        if ($null -eq $overtimeCodes) {
            return @()
        }
        if (-not ($overtimeCodes -is [System.Collections.IEnumerable]) -or ($overtimeCodes -is [string])) {
            return @($overtimeCodes)
        }
        return $overtimeCodes
    }
    catch {
        return @()
    }
}

function Read-JsonRequestBody {
    param($Request)

    $reader = New-Object IO.StreamReader($Request.InputStream)
    try {
        $rawBody = $reader.ReadToEnd()
    }
    finally {
        $reader.Close()
    }

    if ([string]::IsNullOrWhiteSpace($rawBody)) {
        return $null
    }

    return ($rawBody | ConvertFrom-Json)
}

# Helper: Format a time string from "HH:mm:ss" to a history-friendly format ("HHhmm")
function Format-TimeForHistory($timeString) {
    if ($timeString -and $timeString.Length -ge 5) {
        $t = $timeString.Substring(0, 5)  # Get HH:mm
        return $t -replace ":", "h"
    }
    return $timeString
}
