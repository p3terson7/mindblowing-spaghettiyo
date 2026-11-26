$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "../../app/backend/lib/FileStore.ps1")

function Assert-Read([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# Inject a sharing violation at the physical read boundary. Do not lock or
# modify real data and do not sleep; count the exact attempted filesystem work.
function Invoke-SaphirDiagnosticCall {
    param($Name, $Path, $RetryCount, [scriptblock]$Action)
    if ($Name -in @("FileStore.ReadText", "FileStore.ReadBytes")) {
        $script:physicalReads++
        if ($script:physicalReads -le $script:failures) { throw [IO.IOException]::new("Simulated sharing violation") }
    }
    & $Action
}
function Add-SaphirPerformanceOperation { param($Kind, $Path, $Fields) }
function Start-SharedDataRetryDelay {
    param($Attempt)
    $script:delays += $Attempt
}
function Get-FileMetadataSnapshot {
    param($Path)
    $script:metadataProbes++
    return [PSCustomObject]@{ LastWriteTicks = 1; Length = $sourceBytes.Length }
}
function Reset-RetryTest {
    param([int]$Failures)
    Clear-CachedFileContent -Path $path
    $script:failures = $Failures
    $script:physicalReads = 0
    $script:metadataProbes = 0
    $script:delays = @()
}

$script:SaphirPerformanceEnabled = $true
$script:SharedDataReadRetryCount = 6
$path = $PSCommandPath
$sourceText = [IO.File]::ReadAllText($path)
$sourceBytes = [IO.File]::ReadAllBytes($path)

foreach ($reader in @("Read-TextFileCached", "Read-FileBytesCached")) {
    Reset-RetryTest -Failures 100
    $errorStatus = 0
    try { & $reader -Path $path | Out-Null }
    catch { $errorStatus = $_.Exception.Data["SaphirHttpStatusCode"] }
    Assert-Read ($errorStatus -eq 503) "$reader hid or changed the terminal I/O error."
    Assert-Read ($physicalReads -eq 6 -and ($delays -join ",") -eq "1,2,3,4,5") "$reader exceeded one retry budget."
    Assert-Read ($metadataProbes -eq 6) "$reader failed to revalidate metadata on retry."
    Assert-Read (-not ($script:TextFileCache.ContainsKey($path) -or $script:BinaryFileCache.ContainsKey($path))) "$reader published data from a failed read."

    Reset-RetryTest -Failures 2
    $content = & $reader -Path $path
    Assert-Read ($physicalReads -eq 3 -and ($delays -join ",") -eq "1,2") "$reader did not recover promptly from transient I/O errors."
    if ($reader -eq "Read-TextFileCached") {
        Assert-Read ($content -ceq $sourceText) "$reader did not return the source text."
    } else {
        Assert-Read (([Convert]::ToBase64String([byte[]]$content)) -ceq ([Convert]::ToBase64String($sourceBytes))) "$reader did not return the source bytes."
    }
    & $reader -Path $path | Out-Null
    Assert-Read ($physicalReads -eq 3) "$reader did extra physical I/O after a successful cache fill."
}

Reset-RetryTest -Failures 5
Assert-Read ((Read-TextFileWithRetry -Path $path) -ceq $sourceText) "Direct text reads lost their independent retry budget."
Assert-Read ($physicalReads -eq 6 -and $metadataProbes -eq 0) "Direct text reads no longer use the configured read budget."
Write-Host "File read retry tests passed: bounded I/O, metadata revalidation, transient recovery, cache publication and direct reads."
