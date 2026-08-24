$ErrorActionPreference = "Stop"
$WarningPreference = "Continue"

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

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
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-shared-disk-transients-{0}" -f ([Guid]::NewGuid().ToString("N")))
$script:sharedFolder = $tempFolder
$script:lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"
$script:syncStateFile = Join-Path -Path $tempFolder -ChildPath "sync-state.json"
$script:SyncStateWatcherInitialized = $true

try {
    New-Item -ItemType Directory -Path $script:sharedFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $script:lockFolder -Force | Out-Null

    . (Join-Path -Path $repoRoot -ChildPath "app/backend/lib/FileStore.ps1")

    $knownChangeId = [Guid]::NewGuid().ToString("N")
    $knownEmployeeEpoch = [Guid]::NewGuid().ToString("N")
    Write-JsonAtomic -Path $script:syncStateFile -Value ([PSCustomObject]@{
        version               = 17
        changeId              = $knownChangeId
        updatedAtUtc           = (Get-Date).ToUniversalTime().ToString("o")
        category              = "employee"
        resource              = "000123456"
        employeeDataEpoch     = $knownEmployeeEpoch
        employeeDataRevisions = [PSCustomObject]@{
            "000123456" = $knownChangeId
        }
    }) -Depth 8

    . (Join-Path -Path $repoRoot -ChildPath "app/backend/services/SyncService.ps1")

    # Establish one known-good state, then simulate the brief false "missing"
    # result that Windows SMB can expose during a cross-machine replacement.
    $knownState = Get-SyncState
    Assert-Equal -Expected 17 -Actual ([int]$knownState.version) -Message "The fixture sync state was not loaded."
    Assert-Equal -Expected $knownChangeId -Actual ([string]$knownState.changeId) -Message "The fixture sync identity was not loaded."

    Remove-Item -LiteralPath $script:syncStateFile -Force
    Clear-CachedFileContent -Path $script:syncStateFile
    $script:SyncStateDirty = $true
    $script:SyncStateLastValidatedUtc = $null

    $script:OriginalAcquireResourceLockForTransientTest = ${function:Acquire-ResourceLock}
    $script:SyncStateReadLockCount = 0
    function Acquire-ResourceLock {
        param(
            [Parameter(Mandatory = $true)][string]$ResourcePath,
            [int]$TimeoutMs = 30000,
            [int]$StaleLockMs = 120000
        )

        if ([string]$ResourcePath -eq [string]$script:syncStateFile) {
            $script:SyncStateReadLockCount++
            throw "A request-time sync read attempted to acquire a writer lock."
        }

        return (& $script:OriginalAcquireResourceLockForTransientTest -ResourcePath $ResourcePath -TimeoutMs $TimeoutMs -StaleLockMs $StaleLockMs)
    }

    try {
        $fallbackState = Get-SyncState
    }
    finally {
        Remove-Item -Path Function:\Acquire-ResourceLock -ErrorAction SilentlyContinue
        Set-Item -Path Function:\Acquire-ResourceLock -Value $script:OriginalAcquireResourceLockForTransientTest
    }

    Assert-Equal -Expected 0 -Actual $script:SyncStateReadLockCount -Message "A transiently missing sync-state file made a normal request acquire a writer lock."
    Assert-Equal -Expected 17 -Actual ([int]$fallbackState.version) -Message "A transiently missing sync-state file discarded the last known-good version."
    Assert-Equal -Expected $knownChangeId -Actual ([string]$fallbackState.changeId) -Message "A transiently missing sync-state file invented a new change identity."

    # A genuinely busy writer remains protected, but its timeout is a retryable
    # shared-storage condition rather than an unclassified server failure.
    $busyResource = Join-Path -Path $tempFolder -ChildPath "busy-resource.json"
    $busyHandle = Acquire-ResourceLock -ResourcePath $busyResource
    $busyException = $null
    try {
        try {
            Acquire-ResourceLock -ResourcePath $busyResource -TimeoutMs 150 | Out-Null
        }
        catch {
            $busyException = $_.Exception
        }
    }
    finally {
        Release-ResourceLock -LockHandle $busyHandle
    }
    Assert-True -Condition ($null -ne $busyException) -Message "A live writer lock was incorrectly stolen."
    Assert-Equal -Expected 503 -Actual ([int]$busyException.Data["SaphirHttpStatusCode"]) -Message "A shared writer-lock timeout was not marked for HTTP 503."

    # A lock file that can be opened exclusively is not owned by a process. It
    # must be reclaimed immediately even when its timestamp is recent; age alone
    # is neither necessary nor sufficient proof that a lock is abandoned.
    $orphanResource = Join-Path -Path $tempFolder -ChildPath "fresh-orphan.json"
    $orphanLockPath = Get-LockFilePath -ResourcePath $orphanResource
    [System.IO.File]::WriteAllText($orphanLockPath, "orphaned by a terminated process")
    $recoveredHandle = Acquire-ResourceLock -ResourcePath $orphanResource -TimeoutMs 750
    try {
        Assert-True -Condition ($null -ne $recoveredHandle.Stream) -Message "Recovering the abandoned lock did not return a live lock handle."
    }
    finally {
        Release-ResourceLock -LockHandle $recoveredHandle
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath $orphanLockPath -PathType Leaf)) -Message "The recovered lock was not released."

    # Lock ownership and path cleanup are one OS-managed handle lifetime. A
    # second writer must be rejected while that handle is open, and closing it
    # must remove the exact path without a separate unlink that could target a
    # newer owner's lock.
    $atomicReleaseResource = Join-Path -Path $tempFolder -ChildPath "atomic-release.json"
    $atomicReleaseHandle = Acquire-ResourceLock -ResourcePath $atomicReleaseResource
    $atomicReleasePath = [string]$atomicReleaseHandle.Path
    Assert-True -Condition ([System.IO.File]::Exists($atomicReleasePath)) -Message "The live resource lock had no coordination path."

    $secondOpenRejected = $false
    $secondOpen = $null
    try {
        $secondOpen = [System.IO.File]::Open(
            $atomicReleasePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        $secondOpenRejected = $true
    }
    finally {
        if ($null -ne $secondOpen) { $secondOpen.Dispose() }
    }
    Assert-True -Condition $secondOpenRejected -Message "A second owner opened the live lock handle."

    $script:AtomicReleaseManualDeleteCalls = 0
    function Remove-Item {
        param(
            [string]$LiteralPath,
            [string]$Path,
            [switch]$Force,
            $ErrorAction,
            [switch]$Recurse
        )

        $targetPath = if (-not [string]::IsNullOrWhiteSpace([string]$LiteralPath)) { [string]$LiteralPath } else { [string]$Path }
        if ($targetPath -eq $script:atomicReleasePath) {
            $script:AtomicReleaseManualDeleteCalls++
            throw [System.IO.IOException]::new("lock release must not unlink the path manually")
        }

        $parameters = @{}
        if (-not [string]::IsNullOrWhiteSpace([string]$LiteralPath)) { $parameters.LiteralPath = $LiteralPath }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$Path)) { $parameters.Path = $Path }
        if ($Force) { $parameters.Force = $true }
        if ($Recurse) { $parameters.Recurse = $true }
        $parameters.ErrorAction = "Stop"
        Microsoft.PowerShell.Management\Remove-Item @parameters
    }
    $script:atomicReleasePath = $atomicReleasePath

    try {
        Release-ResourceLock -LockHandle $atomicReleaseHandle
    }
    finally {
        Microsoft.PowerShell.Management\Remove-Item -Path Function:\Remove-Item -ErrorAction SilentlyContinue
    }

    Assert-Equal -Expected 0 -Actual $script:AtomicReleaseManualDeleteCalls -Message "Lock release used a racy manual path deletion."
    Assert-True -Condition (-not [System.IO.File]::Exists($atomicReleasePath)) -Message "Closing the ownership handle did not atomically remove its lock path."

    $reacquiredHandle = Acquire-ResourceLock -ResourcePath $atomicReleaseResource -TimeoutMs 750
    Release-ResourceLock -LockHandle $reacquiredHandle
    Assert-True -Condition (-not [System.IO.File]::Exists($atomicReleasePath)) -Message "The released resource lock could not be reacquired cleanly."

    # Initialization failures after CreateNew must also close the ownership
    # handle; otherwise DeleteOnClose cannot run and every later request waits
    # on a lock that this process accidentally stranded.
    $failedInitializationResource = Join-Path -Path $tempFolder -ChildPath "failed-lock-initialization.json"
    $failedInitializationPath = Get-LockFilePath -ResourcePath $failedInitializationResource
    $script:FailedInitializationResource = $failedInitializationResource
    $script:OriginalClearCachedFileContent = ${function:Clear-CachedFileContent}
    function Clear-CachedFileContent {
        param([Parameter(Mandatory = $true)][string]$Path)

        if ([string]$Path -eq [string]$script:FailedInitializationResource) {
            throw [System.IO.IOException]::new("simulated post-open lock initialization failure")
        }
        & $script:OriginalClearCachedFileContent -Path $Path
    }

    $failedInitializationException = $null
    try {
        Acquire-ResourceLock -ResourcePath $failedInitializationResource -TimeoutMs 150 | Out-Null
    }
    catch {
        $failedInitializationException = $_.Exception
    }
    finally {
        Microsoft.PowerShell.Management\Remove-Item -Path Function:\Clear-CachedFileContent -ErrorAction SilentlyContinue
        Set-Item -Path Function:\Clear-CachedFileContent -Value $script:OriginalClearCachedFileContent
    }
    Assert-True -Condition ($null -ne $failedInitializationException) -Message "A failed lock initialization unexpectedly succeeded."
    Assert-True -Condition (-not [System.IO.File]::Exists($failedInitializationPath)) -Message "A failed lock initialization stranded its ownership path."

    # A persistent shared-storage failure is retryable service unavailability,
    # not a missing business record. Inject a real metadata outage through the
    # retry boundary and verify the exception consumed by the server catch.
    $unavailablePath = Join-Path -Path $tempFolder -ChildPath "unavailable.json"
    $script:UnavailableMetadataCalls = 0
    function Get-Item {
        param(
            [string]$LiteralPath,
            [string]$Path,
            $ErrorAction
        )

        $targetPath = if (-not [string]::IsNullOrWhiteSpace([string]$LiteralPath)) { [string]$LiteralPath } else { [string]$Path }
        if ($targetPath -eq $script:unavailablePath) {
            $script:UnavailableMetadataCalls++
            throw [System.IO.IOException]::new("simulated persistent SMB outage")
        }

        $parameters = @{}
        if (-not [string]::IsNullOrWhiteSpace([string]$LiteralPath)) { $parameters.LiteralPath = $LiteralPath }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$Path)) { $parameters.Path = $Path }
        $parameters.ErrorAction = "Stop"
        return (Microsoft.PowerShell.Management\Get-Item @parameters)
    }
    $script:unavailablePath = $unavailablePath

    $unavailableException = $null
    try {
        Get-FileMetadataSnapshot -Path $unavailablePath | Out-Null
    }
    catch {
        $unavailableException = $_.Exception
    }
    finally {
        Remove-Item -Path Function:\Get-Item -ErrorAction SilentlyContinue
    }

    Assert-True -Condition ($null -ne $unavailableException) -Message "A persistent shared-storage outage was silently treated as a missing file."
    Assert-True -Condition ($script:UnavailableMetadataCalls -ge 2) -Message "A transient shared-storage read was not retried before failing."
    Assert-Equal -Expected 503 -Actual ([int]$unavailableException.Data["SaphirHttpStatusCode"]) -Message "A shared-storage outage was not marked for HTTP 503."
    Assert-True -Condition ($unavailableException.Message -match "read metadata") -Message "The shared-storage exception lost its actionable operation context."

    $adminServerSource = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath "app/backend/saphir-server.ps1"))
    Assert-True `
        -Condition ($adminServerSource -match '(?s)requestFailureStatus\s+-eq\s+503.*?Headers\["Retry-After"\].*?respondWithError\s+\$response\s+503') `
        -Message "The central HTTP boundary does not map retryable shared-storage failures to 503 with Retry-After."
    Assert-True `
        -Condition ($adminServerSource -match 'The shared data folder is temporarily unavailable\. Please try again\.') `
        -Message "The HTTP 503 response does not use the safe, stable client message."

    Write-Host "Shared-disk transient recovery tests passed: request sync fallback, atomic lock release, orphan recovery, and HTTP 503 contract."
}
finally {
    Remove-Item -Path Function:\Acquire-ResourceLock -ErrorAction SilentlyContinue
    if ($script:OriginalAcquireResourceLockForTransientTest) {
        Set-Item -Path Function:\Acquire-ResourceLock -Value $script:OriginalAcquireResourceLockForTransientTest
    }
    Remove-Item -Path Function:\Remove-Item -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Get-Item -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Write-Warning -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempFolder) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $tempFolder -Recurse -Force
    }
}
