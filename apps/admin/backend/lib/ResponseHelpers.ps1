# Function to handle errors
function respondWithError($response, $statusCode, $message) {
    $response.StatusCode = $statusCode
    $errorMsg = "{ `"error`": `"$message`" }"
    $response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($errorMsg), 0, ([System.Text.Encoding]::UTF8.GetBytes($errorMsg)).Length)
    $response.Close()
}

# Function to send success responses
function respondWithSuccess($response, $message) {
    $response.ContentType = "application/json"
    $response.StatusCode = 200
    $response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($message), 0, ([System.Text.Encoding]::UTF8.GetBytes($message)).Length)
    $response.Close()
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
    $resolvedRoot = [System.IO.Path]::GetFullPath($FrontendRoot)
    $resolvedCandidate = [System.IO.Path]::GetFullPath($candidatePath)

    if (-not $resolvedCandidate.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
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
        $response.Headers["Cache-Control"] = "no-cache"
    }
    else {
        $response.Headers["Cache-Control"] = "public, max-age=86400"
    }

    if ($request) {
        $ifNoneMatch = [string]$request.Headers["If-None-Match"]
        if (-not [string]::IsNullOrWhiteSpace($ifNoneMatch) -and $ifNoneMatch -eq $etag) {
            $response.StatusCode = 304
            $response.Close()
            return
        }
    }

    $bytes = Read-FileBytesCached -Path $Path
    $response.ContentType = Get-ContentTypeForFilePath -Path $Path
    $response.StatusCode = 200
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.Close()
}
