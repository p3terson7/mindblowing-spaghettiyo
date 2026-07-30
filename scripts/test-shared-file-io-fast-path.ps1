$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
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

$repoRoot = (Get-Item -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..")).FullName
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("saphir-shared-io-fast-path-{0}" -f ([Guid]::NewGuid().ToString("N")))
$script:sharedFolder = $tempFolder
$script:lockFolder = Join-Path -Path $tempFolder -ChildPath ".locks"
$script:mappingFile = Join-Path -Path $tempFolder -ChildPath "employeeNames.json"

try {
    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1")
    . (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/services/EmployeeDirectoryService.ps1")

    $script:OriginalAcquireResourceLockForFastPathTest = ${function:Acquire-ResourceLock}
    $script:AcquireResourceLockCallCount = 0
    function Acquire-ResourceLock {
        param(
            [Parameter(Mandatory = $true)][string]$ResourcePath,
            [int]$TimeoutMs = 30000,
            [int]$StaleLockMs = 120000
        )

        $script:AcquireResourceLockCallCount++
        return (& $script:OriginalAcquireResourceLockForFastPathTest -ResourcePath $ResourcePath -TimeoutMs $TimeoutMs -StaleLockMs $StaleLockMs)
    }

    $existingEmployeeCode = "000000401"
    $existingDataFile = Get-EmployeeDataFilePath -EmployeeCode $existingEmployeeCode
    [System.IO.File]::WriteAllText($existingDataFile, "[]", (New-Object System.Text.UTF8Encoding($false)))

    $resolvedExistingFile = Ensure-EmployeeDataFile -EmployeeCode $existingEmployeeCode
    Assert-Equal -Expected $existingDataFile -Actual $resolvedExistingFile -Message "Existing employee file resolution returned the wrong path."
    Assert-Equal -Expected 0 -Actual $script:AcquireResourceLockCallCount -Message "Resolving an existing employee file acquired a shared writer lock."

    $newEmployeeCode = "000000402"
    $newDataFile = Get-EmployeeDataFilePath -EmployeeCode $newEmployeeCode
    $resolvedNewFile = Ensure-EmployeeDataFile -EmployeeCode $newEmployeeCode
    Assert-Equal -Expected $newDataFile -Actual $resolvedNewFile -Message "New employee file initialization returned the wrong path."
    Assert-Equal -Expected 1 -Actual $script:AcquireResourceLockCallCount -Message "New employee file creation was not protected by a shared writer lock."
    Assert-True -Condition ([System.IO.File]::Exists($newDataFile)) -Message "New employee file initialization did not create the file."
    Assert-Equal -Expected 0 -Actual @(Read-JsonArrayFile -Path $newDataFile).Count -Message "New employee file initialization did not preserve the empty-array contract."

    $tokens = $null
    $parseErrors = $null
    $fileStorePath = Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/lib/FileStore.ps1"
    $fileStoreAst = [System.Management.Automation.Language.Parser]::ParseFile($fileStorePath, [ref]$tokens, [ref]$parseErrors)
    Assert-Equal -Expected 0 -Actual @($parseErrors).Count -Message "FileStore.ps1 has parser errors."
    $arrayReaderAst = $fileStoreAst.Find({
        param($node)
        return ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Read-JsonArrayFile")
    }, $true)
    $arrayReaderCommands = @($arrayReaderAst.FindAll({
        param($node)
        return ($node -is [System.Management.Automation.Language.CommandAst])
    }, $true) | ForEach-Object { [string]$_.GetCommandName() })
    Assert-True -Condition (-not ($arrayReaderCommands -contains "Test-Path")) -Message "Read-JsonArrayFile still performs a redundant existence probe before its cached read."

    $employeeGetRouteSource = [System.IO.File]::ReadAllText(
        (Join-Path -Path $repoRoot -ChildPath "apps/admin/backend/routes/employee/get.routes.ps1")
    )
    Assert-True -Condition $employeeGetRouteSource.Contains('Get-EmployeeDataFilePath -EmployeeCode $employeeCode') -Message "Employee GET no longer resolves its data file without mutation."
    Assert-True -Condition (-not $employeeGetRouteSource.Contains('Ensure-EmployeeDataFile -EmployeeCode $employeeCode')) -Message "Employee GET still initializes or locks its data file."

    Write-Host "Shared-file I/O fast-path tests passed."
}
finally {
    Remove-Item -Path Function:\Acquire-ResourceLock -ErrorAction SilentlyContinue
    if ($script:OriginalAcquireResourceLockForFastPathTest) {
        Set-Item -Path Function:\Acquire-ResourceLock -Value $script:OriginalAcquireResourceLockForFastPathTest
    }
    if (Test-Path -LiteralPath $tempFolder) {
        Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
