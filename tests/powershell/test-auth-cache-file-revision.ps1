$ErrorActionPreference = "Stop"

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$Expected -ne [string]$Actual) {
        throw ("{0} Expected '{1}', found '{2}'." -f $Message, $Expected, $Actual)
    }
}

function Assert-NotEqual {
    param(
        [Parameter(Mandatory = $true)]$ExpectedDifferentFrom,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]$ExpectedDifferentFrom -eq [string]$Actual) {
        throw $Message
    }
}

$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path
$script:usersFile = "fixture-users.json"
$script:sessionsFile = "fixture-sessions.json"
$script:bootstrapAdminUsername = "unused"
$script:bootstrapAdminPassword = "unused"
$script:AuthStorageEnsured = $true
$script:MetadataFailure = $false
$script:MetadataByPath = @{
    $script:usersFile = [PSCustomObject]@{ LastWriteTicks = 100; Length = 10 }
    $script:sessionsFile = [PSCustomObject]@{ LastWriteTicks = 200; Length = 20 }
}
$script:GlobalSyncVersion = 1

function Get-FileMetadataSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($script:MetadataFailure) {
        throw "metadata unavailable"
    }
    return $script:MetadataByPath[$Path]
}

function Get-SyncState {
    return [PSCustomObject]@{ version = $script:GlobalSyncVersion }
}

. (Join-Path -Path $repoRoot -ChildPath "app/backend/services/AuthService.ps1")

$initialKey = Get-AuthSyncVersion
Assert-Equal -Expected "files|100:10|200:20" -Actual $initialKey -Message "Auth cache key did not use users/session metadata."

$script:GlobalSyncVersion = 99
$businessOnlyKey = Get-AuthSyncVersion
Assert-Equal -Expected $initialKey -Actual $businessOnlyKey -Message "An unrelated global data revision invalidated authentication."

$script:MetadataByPath[$script:usersFile] = [PSCustomObject]@{ LastWriteTicks = 101; Length = 11 }
$usersChangedKey = Get-AuthSyncVersion
Assert-NotEqual -ExpectedDifferentFrom $initialKey -Actual $usersChangedKey -Message "A users.json change did not invalidate authentication."

$script:MetadataByPath[$script:sessionsFile] = [PSCustomObject]@{ LastWriteTicks = 201; Length = 21 }
$sessionsChangedKey = Get-AuthSyncVersion
Assert-NotEqual -ExpectedDifferentFrom $usersChangedKey -Actual $sessionsChangedKey -Message "A sessions.json change did not invalidate authentication."

$script:MetadataFailure = $true
$fallbackKey = Get-AuthSyncVersion
Assert-Equal -Expected "sync|99" -Actual $fallbackKey -Message "Auth cache metadata failure did not use the bounded sync fallback."

Write-Host "Auth cache revision test passed: unrelated business revisions preserve auth while users/session changes invalidate it."
