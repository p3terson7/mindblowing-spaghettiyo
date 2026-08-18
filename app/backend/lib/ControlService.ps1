$script:SaphirControlShutdownPath = "/__saphir/control/shutdown"
$script:SaphirControlTokenHeader = "X-SAPHIR-Control-Token"

function Test-SaphirLoopbackAddress {
    param($Address)

    if ($null -eq $Address) {
        return $false
    }

    $ipAddress = $null
    if ($Address -is [System.Net.IPAddress]) {
        $ipAddress = [System.Net.IPAddress]$Address
    }
    elseif (-not [System.Net.IPAddress]::TryParse([string]$Address, [ref]$ipAddress)) {
        return $false
    }

    if ([System.Net.IPAddress]::IsLoopback($ipAddress)) {
        return $true
    }

    if ($ipAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        try {
            if ($ipAddress.IsIPv4MappedToIPv6) {
                return [System.Net.IPAddress]::IsLoopback($ipAddress.MapToIPv4())
            }
        }
        catch {
            return $false
        }
    }

    return $false
}

function Test-SaphirControlToken {
    param(
        [AllowEmptyString()][string]$ExpectedToken,
        [AllowEmptyString()][string]$ProvidedToken
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedToken) -or
        [string]::IsNullOrWhiteSpace($ProvidedToken) -or
        $ExpectedToken.Length -ne $ProvidedToken.Length) {
        return $false
    }

    $difference = 0
    for ($index = 0; $index -lt $ExpectedToken.Length; $index++) {
        $difference = $difference -bor ([int][char]$ExpectedToken[$index] -bxor [int][char]$ProvidedToken[$index])
    }

    return ($difference -eq 0)
}

function Resolve-SaphirControlRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        $RemoteAddress,
        [AllowEmptyString()][string]$ExpectedToken,
        [AllowEmptyString()][string]$ProvidedToken
    )

    if (-not $Path.Equals($script:SaphirControlShutdownPath, [System.StringComparison]::Ordinal)) {
        return [PSCustomObject]@{
            IsControlRequest = $false
            ShouldShutdown   = $false
            StatusCode       = 0
            Message          = ""
        }
    }

    if (-not $Method.Equals("POST", [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{
            IsControlRequest = $true
            ShouldShutdown   = $false
            StatusCode       = 405
            Message          = "Method not allowed."
        }
    }

    if (-not (Test-SaphirLoopbackAddress -Address $RemoteAddress)) {
        return [PSCustomObject]@{
            IsControlRequest = $true
            ShouldShutdown   = $false
            StatusCode       = 403
            Message          = "Control requests are restricted to this computer."
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedToken)) {
        return [PSCustomObject]@{
            IsControlRequest = $true
            ShouldShutdown   = $false
            StatusCode       = 503
            Message          = "Service control is unavailable for this process."
        }
    }

    if (-not (Test-SaphirControlToken -ExpectedToken $ExpectedToken -ProvidedToken $ProvidedToken)) {
        return [PSCustomObject]@{
            IsControlRequest = $true
            ShouldShutdown   = $false
            StatusCode       = 403
            Message          = "Invalid service control token."
        }
    }

    return [PSCustomObject]@{
        IsControlRequest = $true
        ShouldShutdown   = $true
        StatusCode       = 202
        Message          = "SAPHIR is stopping."
    }
}
