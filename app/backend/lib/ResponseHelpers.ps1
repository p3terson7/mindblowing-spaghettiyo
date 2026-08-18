function Write-HttpResponseSafely {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
        [string]$ContentType = "application/json; charset=utf-8"
    )

    try {
        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $Response.ContentLength64 = $Bytes.Length
        if ($Bytes.Length -gt 0) {
            $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
        }
    }
    catch {
        # A disconnected client must not terminate the single server loop.
        Write-Verbose ("Unable to complete HTTP response: {0}" -f $_.Exception.Message)
    }
    finally {
        try {
            $Response.Close()
        }
        catch {
            # Closing an aborted response is best effort.
        }
    }
}

function ConvertTo-NormalizedHttpOrigin {
    param([AllowNull()][string]$Origin)

    $candidate = ([string]$Origin).Trim().TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -eq "null") {
        return ""
    }

    try {
        $uri = [System.Uri]$candidate
    }
    catch {
        return ""
    }

    if (-not $uri.IsAbsoluteUri -or
        @("http", "https") -notcontains $uri.Scheme.ToLowerInvariant() -or
        -not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or
        $uri.AbsolutePath -ne "/" -or
        -not [string]::IsNullOrWhiteSpace($uri.Query) -or
        -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        return ""
    }

    return $uri.GetLeftPart([System.UriPartial]::Authority).TrimEnd("/")
}

function Set-CorsHeadersForRequest {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)]$Response,
        [string[]]$AllowedOrigins = @()
    )

    $rawOrigin = [string]$Request.Headers["Origin"]
    if ([string]::IsNullOrWhiteSpace($rawOrigin)) {
        return $true
    }

    $requestOrigin = ConvertTo-NormalizedHttpOrigin -Origin $Request.Url.GetLeftPart([System.UriPartial]::Authority)
    $normalizedOrigin = ConvertTo-NormalizedHttpOrigin -Origin $rawOrigin
    if ([string]::IsNullOrWhiteSpace($normalizedOrigin)) {
        return $false
    }

    $originAllowed = $normalizedOrigin -eq $requestOrigin
    if (-not $originAllowed -and -not [string]::IsNullOrWhiteSpace($requestOrigin)) {
        $originUri = [System.Uri]$normalizedOrigin
        $requestOriginUri = [System.Uri]$requestOrigin
        $originAllowed = $originUri.IsLoopback -and
            $requestOriginUri.IsLoopback -and
            $originUri.Scheme -eq $requestOriginUri.Scheme -and
            $originUri.Port -eq $requestOriginUri.Port
    }
    if (-not $originAllowed) {
        foreach ($allowedOrigin in @($AllowedOrigins)) {
            if ($normalizedOrigin -eq (ConvertTo-NormalizedHttpOrigin -Origin ([string]$allowedOrigin))) {
                $originAllowed = $true
                break
            }
        }
    }
    if (-not $originAllowed) {
        return $false
    }

    $Response.Headers["Access-Control-Allow-Origin"] = $normalizedOrigin
    $varyHeader = [string]$Response.Headers["Vary"]
    if (@($varyHeader -split "," | ForEach-Object { $_.Trim() }) -notcontains "Origin") {
        $Response.Headers["Vary"] = if ([string]::IsNullOrWhiteSpace($varyHeader)) {
            "Origin"
        }
        else {
            "$varyHeader, Origin"
        }
    }
    return $true
}

# Function to handle errors
function respondWithError($response, $statusCode, $message) {
    $errorMsg = ConvertTo-Json -InputObject ([PSCustomObject]@{
        error = [string]$message
    }) -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($errorMsg)
    Write-HttpResponseSafely -Response $response -StatusCode ([int]$statusCode) -Bytes $bytes
}

function Rethrow-HttpStatusException {
    param($Exception)

    if ($null -ne $Exception -and
        $null -ne $Exception.Data -and
        $Exception.Data.Contains("SaphirHttpStatusCode")) {
        throw $Exception
    }
}

# Function to send success responses
function respondWithSuccess($response, $message) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$message)
    Write-HttpResponseSafely -Response $response -StatusCode 200 -Bytes $bytes
}

function respondWithDownload {
    param(
        [Parameter(Mandatory = $true)]$response,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $safeFileName = ([string]$FileName) -replace "[`r`n`"]", "_"
    try {
        $response.ContentType = $ContentType
        $response.StatusCode = 200
        $response.ContentLength64 = $Bytes.Length
        $response.Headers["Content-Disposition"] = ("attachment; filename=""{0}""" -f $safeFileName)
        $response.Headers["Access-Control-Expose-Headers"] = "Content-Disposition, Content-Type"
        $response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        $response.Headers["Pragma"] = "no-cache"
        $response.Headers["Expires"] = "0"
        $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    }
    catch {
        Write-Verbose ("Unable to complete download response: {0}" -f $_.Exception.Message)
    }
    finally {
        try { $response.Close() } catch { }
    }
}

function Get-ContentTypeForFilePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { return "text/html; charset=utf-8" }
        ".css" { return "text/css; charset=utf-8" }
        ".js" { return "application/javascript; charset=utf-8" }
        ".json" { return "application/json; charset=utf-8" }
        ".png" { return "image/png" }
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".svg" { return "image/svg+xml" }
        ".ico" { return "image/x-icon" }
        ".woff" { return "font/woff" }
        ".woff2" { return "font/woff2" }
        ".ttf" { return "font/ttf" }
        default { return "application/octet-stream" }
    }
}

function Resolve-FrontendFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$FrontendRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $decodedPath = [System.Uri]::UnescapeDataString($RelativePath.TrimStart("/"))
    if ([string]::IsNullOrWhiteSpace($decodedPath)) {
        $decodedPath = "index.html"
    }

    $candidatePath = Join-Path -Path $FrontendRoot -ChildPath ($decodedPath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    $pathSeparators = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $resolvedRoot = [System.IO.Path]::GetFullPath($FrontendRoot).TrimEnd($pathSeparators)
    $resolvedCandidate = [System.IO.Path]::GetFullPath($candidatePath)
    $rootBoundary = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar

    if (-not $resolvedCandidate.StartsWith($rootBoundary, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if (-not (Test-Path -Path $resolvedCandidate -PathType Leaf)) {
        return $null
    }

    return $resolvedCandidate
}

function respondWithFile {
    param(
        [Parameter(Mandatory = $true)]$response,
        [Parameter(Mandatory = $true)][string]$Path,
        $request
    )

    $metadata = Get-FileMetadataSnapshot -Path $Path
    if ($null -eq $metadata) {
        respondWithError $response 404 "File not found."
        return
    }

    $etag = '"{0}-{1}"' -f $metadata.Length, $metadata.LastWriteTicks
    $response.Headers["ETag"] = $etag
    $response.Headers["Last-Modified"] = $metadata.LastWriteUtc.ToString("R")

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq ".html") {
        $response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        $response.Headers["Pragma"] = "no-cache"
        $response.Headers["Expires"] = "0"
    }
    elseif ($extension -eq ".js" -or $extension -eq ".css") {
        $response.Headers["Cache-Control"] = "public, max-age=3600, must-revalidate"
    }
    else {
        $response.Headers["Cache-Control"] = "public, max-age=86400"
    }

    if ($request) {
        $ifNoneMatch = [string]$request.Headers["If-None-Match"]
        if (-not [string]::IsNullOrWhiteSpace($ifNoneMatch) -and $ifNoneMatch -eq $etag) {
            Write-HttpResponseSafely -Response $response -StatusCode 304 -Bytes ([byte[]]@()) -ContentType (Get-ContentTypeForFilePath -Path $Path)
            return
        }
    }

    $bytes = Read-FileBytesCached -Path $Path
    Write-HttpResponseSafely -Response $response -StatusCode 200 -Bytes $bytes -ContentType (Get-ContentTypeForFilePath -Path $Path)
}
