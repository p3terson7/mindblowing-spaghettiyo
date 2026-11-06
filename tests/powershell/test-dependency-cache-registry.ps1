param([switch]$Isolated)
$ErrorActionPreference = "Stop"
if (-not $Isolated) {
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath -Isolated
    if ($LASTEXITCODE -ne 0) { throw "Dependency registry subprocess failed." }
    return
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo "app/backend/services/ReadModelService.ps1")
function Sync-ReadModelCaches { }
function Assert-Registry($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$script:Factories = 0
$child = Invoke-ReadModelCache -Key child -Dependencies @("employee:001") -Factory { $script:Factories++; [PSCustomObject]@{ value = 1 } }
$parent = Invoke-ReadModelCache -Key parent -Dependencies @("projects") -Factory {
    Invoke-ReadModelCache -Key child -Dependencies @("employee:001") -Factory { throw "Child should hit" }
}
$other = Invoke-ReadModelCache -Key other -Dependencies @("employee:002") -Factory { [PSCustomObject]@{ value = 2 } }
Remove-DependentReadModels -ChangedSources @("employee:001")
Assert-Registry (-not $script:ReadModelCache.ContainsKey("child") -and -not $script:ReadModelCache.ContainsKey("parent")) "Hit dependencies were not propagated transitively to the parent."
Assert-Registry ([object]::ReferenceEquals($other, $script:ReadModelCache.other)) "An independent source was evicted."
Invoke-ReadModelCache -Key money -Dependencies @("compensation", "employee:002") -Factory { 1 } | Out-Null
Remove-DependentReadModels -ChangedSources @("compensation")
Assert-Registry (-not $script:ReadModelCache.ContainsKey("money") -and $script:ReadModelCache.ContainsKey("other")) "Monetary invalidation affected nonmonetary data."
Invoke-ReadModelCache -Key undeclared -Factory { 1 } | Out-Null
Remove-DependentReadModels -ChangedSources @("bugs")
Assert-Registry (-not $script:ReadModelCache.ContainsKey("undeclared") -and $script:ReadModelCache.ContainsKey("other")) "Undeclared factories must fall back conservatively."
try { Invoke-ReadModelCache -Key failure -Dependencies @("history") -Factory { throw "expected" } } catch { }
Assert-Registry ($script:ReadModelFactoryDepth -eq 0 -and $script:ReadModelDependencyFrames.Count -eq 0 -and -not $script:ReadModelCache.ContainsKey("failure")) "Failed factories leaked a frame or cached an incomplete result."
foreach ($index in 1..520) { Invoke-ReadModelCache -Key "bounded-$index" -Dependencies @("budget") -Factory { $index } | Out-Null }
Assert-Registry ($script:ReadModelCache.Count -le $script:ReadModelCacheCapacity -and $script:ReadModelCache.Count -eq $script:ReadModelDependencies.Count -and $script:ReadModelCache.Count -eq $script:ReadModelLastAccess.Count) "Registry grew unbounded or leaked dependencies/access entries after eviction."
Remove-DependentReadModels
$previousCapacity = $script:ReadModelCacheCapacity
$script:ReadModelCacheCapacity = 16
foreach ($index in 1..16) { Invoke-ReadModelCache -Key "lru-$index" -Dependencies @("employee:$index") -Factory { $index } | Out-Null }
Invoke-ReadModelCache -Key "lru-1" -Factory { throw "Expected hit" } | Out-Null
Invoke-ReadModelCache -Key "lru-new" -Dependencies @("budget") -Factory { 99 } | Out-Null
Assert-Registry ($script:ReadModelCache.ContainsKey("lru-1") -and -not $script:ReadModelCache.ContainsKey("lru-2") -and $script:ReadModelCache.Count -eq 16) "Capacity eviction was not selective LRU."
Invoke-ReadModelCache -Key "lru-parent" -Dependencies @("projects") -Factory {
    Invoke-ReadModelCache -Key "lru-1" -Dependencies @("employee:1") -Factory { throw "Expected transitive hit" }
} | Out-Null
Remove-DependentReadModels -ChangedSources @("employee:1")
Assert-Registry (-not $script:ReadModelCache.ContainsKey("lru-parent") -and $script:ReadModelCache.ContainsKey("lru-new")) "Eviction lost transitive invalidation or removed unrelated models."
Remove-DependentReadModels
$script:ReadModelCacheCapacity = $previousCapacity

$oldId = [Guid]::NewGuid().ToString("N")
$newId = [Guid]::NewGuid().ToString("N")
$previous = [PSCustomObject]@{ dependencySchemaVersion = 1; sourceRevisions = @{ employee = $oldId; project = $oldId }; category = "employee"; changeId = $oldId }
$current = [PSCustomObject]@{ dependencySchemaVersion = 1; sourceRevisions = @{ employee = $newId; project = $oldId; history = $newId }; category = "history"; changeId = $newId }
$changed = @(Get-ReadModelChangedCategories $previous $current $false)
Assert-Registry ($changed -contains "employee" -and $changed -contains "history" -and $changed -notcontains "project") "Cumulative category vector missed changes between checks."
$current.sourceRevisions.history = "malformed"
Assert-Registry (@(Get-ReadModelChangedCategories $previous $current $false) -contains "*") "Malformed category revision was trusted."
Assert-Registry (@(Get-ReadModelChangedCategories $previous $current $true) -contains "*") "Malformed sequential category revision was trusted."
$legacy = [PSCustomObject]@{ category = "employee"; changeId = $newId }
Assert-Registry (@(Get-ReadModelChangedCategories $previous $legacy $false) -contains "*") "A legacy category vector described a skipped notification."
Write-Host "Dependency registry passed: transitive hits, selective sources, money isolation, unknown dependencies, factory failure, bounded lifecycle, cumulative vectors and legacy/malformed fallback."
