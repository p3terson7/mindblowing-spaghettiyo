$ErrorActionPreference = "Stop"

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
. (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/FileStore.ps1")
. (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/ResponseHelpers.ps1")

$script:WriteCallCount = 0
$script:ResponseClosed = $false
$emptyStream = [PSCustomObject]@{}
$emptyStream | Add-Member -MemberType ScriptMethod -Name Write -Value {
    param($Bytes, $Offset, $Count)
    $script:WriteCallCount++
}

$emptyResponse = [PSCustomObject]@{
    StatusCode     = 0
    ContentType    = ""
    ContentLength64 = -1L
    OutputStream   = $emptyStream
}
$emptyResponse | Add-Member -MemberType ScriptMethod -Name Close -Value {
    $script:ResponseClosed = $true
}

# A conditional GET legitimately returns no bytes. PowerShell must accept the
# empty byte array instead of failing parameter binding before the response is
# completed.
Write-HttpResponseSafely `
    -Response $emptyResponse `
    -StatusCode 304 `
    -Bytes ([byte[]]@()) `
    -ContentType "application/javascript; charset=utf-8"

Assert-Equal -Expected 304 -Actual $emptyResponse.StatusCode -Message "The empty response did not preserve its HTTP status."
Assert-Equal -Expected 0 -Actual $emptyResponse.ContentLength64 -Message "The empty response did not declare a zero content length."
Assert-Equal -Expected 0 -Actual $script:WriteCallCount -Message "The empty response attempted an unnecessary stream write."
Assert-Equal -Expected $true -Actual $script:ResponseClosed -Message "The empty response was not closed."

$temporaryFile = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($temporaryFile, "cached asset", (New-Object System.Text.UTF8Encoding($false)))
    $metadata = Get-FileMetadataSnapshot -Path $temporaryFile
    $etag = '"{0}-{1}"' -f $metadata.Length, $metadata.LastWriteTicks

    $script:WriteCallCount = 0
    $script:ResponseClosed = $false
    $conditionalResponse = [PSCustomObject]@{
        StatusCode      = 0
        ContentType     = ""
        ContentLength64 = -1L
        Headers         = @{}
        OutputStream    = $emptyStream
    }
    $conditionalResponse | Add-Member -MemberType ScriptMethod -Name Close -Value {
        $script:ResponseClosed = $true
    }
    $conditionalRequest = [PSCustomObject]@{
        Headers = @{ "If-None-Match" = $etag }
    }

    respondWithFile -response $conditionalResponse -Path $temporaryFile -request $conditionalRequest

    Assert-Equal -Expected 304 -Actual $conditionalResponse.StatusCode -Message "A matching ETag did not produce a 304 response."
    Assert-Equal -Expected 0 -Actual $conditionalResponse.ContentLength64 -Message "The 304 response did not declare a zero content length."
    Assert-Equal -Expected 0 -Actual $script:WriteCallCount -Message "The 304 response attempted an unnecessary stream write."
    Assert-Equal -Expected $true -Actual $script:ResponseClosed -Message "The 304 response was not closed."
}
finally {
    Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Empty HTTP response tests passed."
