# Local, single-runspace cache infrastructure. Dependencies belong to the
# factory, not to the HTTP route. A parent inherits dependencies of its children
# on BOTH hits and misses. Values remain in the existing ReadModelCache.
if ($null -eq $script:ReadModelDependencies) { $script:ReadModelDependencies = @{} }
if ($null -eq $script:ReadModelDependencyFrames) { $script:ReadModelDependencyFrames = New-Object Collections.ArrayList }
if ($null -eq $script:ReadModelSourceStamps) { $script:ReadModelSourceStamps = @{} }
if ($null -eq $script:ReadModelReconciledUtc) { $script:ReadModelReconciledUtc = [DateTime]::UtcNow }
if ($null -eq $script:ReadModelContentReconciledUtc) { $script:ReadModelContentReconciledUtc = [DateTime]::UtcNow }
if ($null -eq $script:ReadModelLastAccess) { $script:ReadModelLastAccess = @{} }
if ($null -eq $script:ReadModelAccessSequence) { $script:ReadModelAccessSequence = [long]0 }
if ($null -eq $script:ReadModelCacheCapacity) {
    $configuredCapacity = 0
    [int]::TryParse([string]$env:SAPHIR_READ_MODEL_CACHE_CAPACITY, [ref]$configuredCapacity) | Out-Null
    # 500 employees require 1,005 dashboard models; the SMB/memory comparison
    # measured this capacity instead of assuming a model count is a RAM limit.
    $script:ReadModelCacheCapacity = if ($configuredCapacity -ge 16 -and $configuredCapacity -le 4096) { $configuredCapacity } else { 1024 }
}

function Add-ReadModelDependenciesToParent {
    param([string[]]$Dependencies)
    if ($script:ReadModelDependencyFrames.Count -gt 0) {
        $parent = $script:ReadModelDependencyFrames[$script:ReadModelDependencyFrames.Count - 1]
        foreach ($dependency in $Dependencies) { $parent[$dependency] = $true }
    }
}

function Remove-DependentReadModels {
    param([string[]]$ChangedSources = @("*"))
    $diagnosticAffectedModels = 0
    foreach ($key in @($script:ReadModelCache.Keys)) {
        $dependencies = $script:ReadModelDependencies[$key]
        $invalidate = $ChangedSources -contains "*" -or $null -eq $dependencies -or $dependencies -contains "*"
        foreach ($source in $ChangedSources) {
            if ($dependencies -contains $source -or
                ($source.StartsWith("employee:") -and $dependencies -contains "employee:*")) { $invalidate = $true }
            if ($source -eq "employee:*" -and @($dependencies | Where-Object { $_.StartsWith("employee:") }).Count -gt 0) { $invalidate = $true }
        }
        if ($invalidate) {
            $diagnosticAffectedModels++
            $script:ReadModelCache.Remove($key) | Out-Null
            $script:ReadModelDependencies.Remove($key) | Out-Null
            $script:ReadModelLastAccess.Remove($key) | Out-Null
            if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.model.invalidated" -Fields @{ modelId = Get-SaphirPerformanceModelId $key; modelCategory = ($key -split '\|')[0]; reason = "dependency-source-change" } }
        }
    }
    if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.invalidation" -Fields @{ affectedModels = $diagnosticAffectedModels; cacheSize = $script:ReadModelCache.Count; reason = if ($ChangedSources -contains "*") { "conservative-reset" } else { "dependency-source-change" } } }
    if ($ChangedSources -contains "*" -and $script:SaphirPerformanceEnabled) {
        Add-SaphirPerformanceOperation -Kind "cache.reconciliation.full"
    }
}

function Notify-ReadModelSourceCommitted {
    param([string]$Path)
    # Local coherence even if the process cannot publish afterwards. Other
    # processes retain their source stamps for the bounded reconciliation.
    if ([IO.Path]::GetFileName($Path) -eq "sync-state.json") { return }
    $source = Get-ReadModelSourceForPath -Path $Path
    $sources = @($source)
    if ($source -eq "auth") { $sources += @("directory", "compensation") }
    Remove-DependentReadModels -ChangedSources $sources
}

function Invoke-ReadModelCache {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][scriptblock]$Factory,
        [string[]]$Dependencies = @("*")
    )
    if ($script:ReadModelFactoryDepth -le 0) { Sync-ReadModelCaches }
    $lookupSpan = if ($script:SaphirPerformanceRecord.level -eq "detailed") { Start-SaphirPerformanceSpan -Name "ReadModelCache.Lookup" -Component "ReadModelCacheService" -Type "cache" -Fields @{ cacheSize = $script:ReadModelCache.Count; modelId = Get-SaphirPerformanceModelId $Key; modelCategory = ($Key -split '\|')[0]; filesystemAccess = $false } } else { $null }
    if ($script:ReadModelCache.ContainsKey($Key)) {
        if ($lookupSpan) { $lookupSpan.fields.cache = "hit"; $lookupSpan.fields.servedFromCache = $true; Stop-SaphirPerformanceSpan $lookupSpan }
        $script:ReadModelAccessSequence++
        $script:ReadModelLastAccess[$Key] = $script:ReadModelAccessSequence
        Add-ReadModelDependenciesToParent -Dependencies $script:ReadModelDependencies[$Key]
        if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.readmodel.hit" -Fields @{ modelId = Get-SaphirPerformanceModelId $Key; modelCategory = ($Key -split '\|')[0]; cacheSize = $script:ReadModelCache.Count } }
        return $script:ReadModelCache[$Key]
    }
    if ($lookupSpan) { $lookupSpan.fields.cache = "miss"; $lookupSpan.fields.servedFromCache = $false; Stop-SaphirPerformanceSpan $lookupSpan }
    $frame = @{}
    foreach ($dependency in $Dependencies) { $frame[$dependency] = $true }
    [void]$script:ReadModelDependencyFrames.Add($frame)
    $script:ReadModelFactoryDepth++
    if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.readmodel.miss" -Fields @{ modelId = Get-SaphirPerformanceModelId $Key; modelCategory = ($Key -split '\|')[0]; cacheSize = $script:ReadModelCache.Count; reason = "absent-or-invalidated" } }
    $factorySpan = if ($script:SaphirPerformanceRecord.level -eq "detailed") { Start-SaphirPerformanceSpan -Name "ReadModelCache.Construct" -Component "ReadModelCacheService" -Type "function" -Fields @{ modelId = Get-SaphirPerformanceModelId $Key; modelCategory = ($Key -split '\|')[0] } } else { $null }
    $factoryStatus = "success"; $factoryError = $null
    try { $value = & $Factory }
    catch { $factoryStatus = "error"; $factoryError = $_; throw }
    finally {
        if ($factorySpan) { Stop-SaphirPerformanceSpan $factorySpan -Status $factoryStatus -ErrorRecord $factoryError }
        $script:ReadModelFactoryDepth--
        $script:ReadModelDependencyFrames.RemoveAt($script:ReadModelDependencyFrames.Count - 1)
    }
    # Evict one least-recently used value, not every independent contribution.
    # Parent frames retain inherited source dependencies even if a child was
    # evicted before the parent completed. No cached value/dependency is orphaned.
    if ($script:ReadModelCache.Count -ge $script:ReadModelCacheCapacity) {
        $oldest = $null; $sequence = [long]::MaxValue
        foreach ($candidate in $script:ReadModelCache.Keys) {
            $access = [long]$script:ReadModelLastAccess[$candidate]
            if ($null -eq $oldest -or $access -lt $sequence) { $oldest = $candidate; $sequence = $access }
        }
        $script:ReadModelCache.Remove($oldest) | Out-Null
        $script:ReadModelDependencies.Remove($oldest) | Out-Null
        $script:ReadModelLastAccess.Remove($oldest) | Out-Null
        if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.model.evicted" -Fields @{ reason = "lru-capacity"; cacheSize = $script:ReadModelCache.Count } }
    }
    $script:ReadModelCache[$Key] = $value
    $script:ReadModelDependencies[$Key] = @($frame.Keys)
    $script:ReadModelAccessSequence++
    $script:ReadModelLastAccess[$Key] = $script:ReadModelAccessSequence
    if ($script:ReadModelFactoryDepth -eq 0) {
        foreach ($entry in @($script:FileMetadataCache.Values)) {
            if ($null -ne $entry.Metadata -and -not $script:ReadModelSourceStamps.ContainsKey([string]$entry.Metadata.Path)) {
                $script:ReadModelSourceStamps[[string]$entry.Metadata.Path] = $entry.Metadata
            }
        }
    }
    Add-ReadModelDependenciesToParent -Dependencies @($frame.Keys)
    return $value
}

function Get-ReadModelSourceForPath {
    param([string]$Path)
    $attachmentRoot = Join-Path ([string]$sharedFolder) "bug-report-attachments"
    if ($Path.StartsWith(($attachmentRoot.TrimEnd([char[]]@([char]47, [char]92)) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { return "bugs" }
    $name = [IO.Path]::GetFileName($Path)
    if ($name -match '^(\d+)_data\.json$') { return "employee:$($Matches[1])" }
    switch ($name) {
        "users.json" { return "auth" }
        "sessions.json" { return "sessions" }
        "employeeNames.json" { return "directory" }
        "projects.json" { return "projects" }
        "compensation-grid.json" { return "compensation" }
        "budget-periods.json" { return "budget" }
        "history.json" { return "history" }
        "bug-reports.json" { return "bugs" }
        default { return "*" }
    }
}

function Get-ReadModelChangedCategories {
    param($PreviousState, $CurrentState, [bool]$Sequential)
    $known = @("employee", "employee-directory", "history", "project", "auth", "sessions", "compensation", "budget-periods", "bug-reports")
    if ($Sequential -and $CurrentState.PSObject.Properties.Name -notcontains "sourceRevisions") { return @([string]$CurrentState.category) }
    $states = if ($Sequential) { @($CurrentState) } else { @($PreviousState, $CurrentState) }
    foreach ($state in $states) {
        if ($null -eq $state -or $state.dependencySchemaVersion -ne 1 -or
            $null -eq $state.sourceRevisions -or
            -not (($state.sourceRevisions -is [Collections.IDictionary]) -or
                $state.sourceRevisions.PSObject.TypeNames -contains "System.Management.Automation.PSCustomObject")) { return @("*") }
        $sources = ConvertTo-ReadModelEmployeeRevisionMap $state.sourceRevisions
        foreach ($key in $sources.Keys) {
            if ($known -notcontains $key -or -not (Test-ReadModelGuidValue $sources[$key])) { return @("*") }
        }
    }
    if ($Sequential) {
        $sources = ConvertTo-ReadModelEmployeeRevisionMap $CurrentState.sourceRevisions
        if ($sources[[string]$CurrentState.category] -ne [string]$CurrentState.changeId) { return @("*") }
        return @([string]$CurrentState.category)
    }
    $before = ConvertTo-ReadModelEmployeeRevisionMap $PreviousState.sourceRevisions
    $after = ConvertTo-ReadModelEmployeeRevisionMap $CurrentState.sourceRevisions
    if (-not $after.ContainsKey([string]$CurrentState.category) -or
        $after[[string]$CurrentState.category] -ne [string]$CurrentState.changeId) { return @("*") }
    $changed = @{}
    foreach ($key in @($before.Keys) + @($after.Keys)) {
        if ($before[$key] -ne $after[$key]) { $changed[$key] = $true }
    }
    if ($changed.Count -eq 0) { return @("*") }
    return @($changed.Keys)
}

function Get-ReadModelStateFingerprint {
    param($State)
    # PowerShell 7 parses ISO timestamps into DateTime, whereas publishers hold
    # strings. updatedAtUtc is descriptive, not a source revision; excluding it
    # avoids false conflicts caused solely by date serialization normalization.
    return ($State | Select-Object * -ExcludeProperty updatedAtUtc | ConvertTo-Json -Depth 8 -Compress)
}

function Invoke-ReadModelSourceReconciliation {
    # Keep the existing 30s metadata safety boundary. Every 5 minutes force
    # fresh contents too: publication may fail, old clients may not publish,
    # and an external replacement can preserve BOTH timestamp and length.
    # No new shared files, durable outbox, or distributed transaction is needed.
    $now = [DateTime]::UtcNow
    if (($now - $script:ReadModelContentReconciledUtc).TotalSeconds -ge 300) {
        if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.reconciliation.fallback" -Fields @{ reason = "periodic-content-safety" } }
        Remove-DependentReadModels
        Clear-AllEmployeeEntryCaches
        Clear-AllReadModelCoreFileCaches
        $script:ReadModelContentReconciledUtc = $now
        $script:ReadModelReconciledUtc = $now
        return
    }
    if (($now - $script:ReadModelReconciledUtc).TotalMilliseconds -lt $script:FileMetadataValidationIntervalMs) { return }
    # Snapshot first: invalidating source caches mutates this dictionary.
    $snapshots = @($script:ReadModelSourceStamps.Values)
    $script:ReadModelReconciledUtc = $now
    foreach ($snapshot in $snapshots) {
        $old = $snapshot
        if ($null -eq $old) { continue }
        $path = [string]$old.Path
        $root = ([string]$sharedFolder).TrimEnd([char[]]@([char]47, [char]92)) + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([IO.Path]::GetFileName($path) -eq "sync-state.json") { continue }
        $cachedMetadata = $script:FileMetadataCache[$path].Metadata
        # Use only a successful metadata observation, not ValidatedAtUtc:
        # FileStore can renew that latter TTL after a failed SMB probe.
        if ($cachedMetadata -and $cachedMetadata.ObservedAtUtc -and
            $cachedMetadata.LastWriteTicks -eq $old.LastWriteTicks -and $cachedMetadata.Length -eq $old.Length -and
            ($now - $cachedMetadata.ObservedAtUtc).TotalMilliseconds -lt $script:FileMetadataValidationIntervalMs) { continue }
        try { $item = Get-FileItemWithRetry -Path $path }
        catch {
            if ($script:SaphirPerformanceEnabled) { Add-SaphirPerformanceOperation -Kind "cache.reconciliation.fallback" -Fields @{ reason = "metadata-probe-failure" } }
            # Never mark a failed probe as a successful validation. The next
            # sync reconnect is also a conservative reset.
            Remove-DependentReadModels
            Clear-AllEmployeeEntryCaches
            Clear-AllReadModelCoreFileCaches
            return
        }
        if ($null -eq $item -or $item.LastWriteTimeUtc.Ticks -ne $old.LastWriteTicks -or $item.Length -ne $old.Length) {
            $source = Get-ReadModelSourceForPath -Path $path
            Remove-DependentReadModels -ChangedSources @($source)
            if ($source.StartsWith("employee:")) {
                Clear-EmployeeEntryCacheForCode -EmployeeCode $source.Substring(9) | Out-Null
            }
            else {
                $category = switch ($source) {
                    "directory" { "employee-directory" }
                    "projects" { "project" }
                    "budget" { "budget-periods" }
                    "bugs" { "bug-reports" }
                    default { $source }
                }
                Clear-ReadModelCoreCachesForChange -Category $category -CanUseTargetedInvalidation:$true
            }
            Clear-CachedFileContent -Path $path
            $script:ReadModelSourceStamps.Remove($path) | Out-Null
        }
        else {
            # A successful reconciliation is also a valid FileStore metadata
            # observation; avoid repeating its Get-Item in the next file read.
            $metadata = [PSCustomObject]@{ Path = $path; LastWriteUtc = $item.LastWriteTimeUtc; LastWriteTicks = $item.LastWriteTimeUtc.Ticks; Length = $item.Length; ObservedAtUtc = $now }
            $script:FileMetadataCache[$path] = [PSCustomObject]@{ ValidatedAtUtc = $now; Metadata = $metadata }
        }
    }
}
