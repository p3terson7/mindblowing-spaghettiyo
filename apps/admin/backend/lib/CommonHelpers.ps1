# Helper function to emulate the null-coalescing operator
function Get-EmployeeNameMap {
    if (!(Test-Path -Path $mappingFile)) {
        Write-JsonAtomic -Path $mappingFile -Value @{} -Depth 3
    }

    try {
        $map = Read-TextFileCached -Path $mappingFile | ConvertFrom-Json
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
        Write-JsonAtomic -Path $projectsFile -Value @() -Depth 3
    }

    try {
        $projects = Read-TextFileCached -Path $projectsFile | ConvertFrom-Json
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
        Write-JsonAtomic -Path $overtimeCodesFile -Value @() -Depth 3
    }

    try {
        $overtimeCodes = Read-TextFileCached -Path $overtimeCodesFile | ConvertFrom-Json
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

function Read-JsonOptionArray {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (!(Test-Path -Path $Path)) {
        Write-JsonAtomic -Path $Path -Value @() -Depth 3
    }

    try {
        $items = Read-TextFileCached -Path $Path | ConvertFrom-Json
        if ($null -eq $items) {
            return @()
        }
        if (-not ($items -is [System.Collections.IEnumerable]) -or ($items -is [string])) {
            return @($items)
        }
        return $items
    }
    catch {
        return @()
    }
}

function Get-PaymentOptions {
    return (Read-JsonOptionArray -Path $paymentOptionsFile)
}

function Get-ReasonCodes {
    return (Read-JsonOptionArray -Path $reasonCodesFile)
}

function Test-OptionCode {
    param(
        [Parameter(Mandatory = $true)]$Options,
        [AllowNull()][string]$Code,
        [bool]$AllowBlank = $false
    )

    $candidate = [string]$Code
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $AllowBlank
    }

    return [bool](@($Options | Where-Object { [string]$_.code -eq $candidate } | Select-Object -First 1).Count -gt 0)
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
