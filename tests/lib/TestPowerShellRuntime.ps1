function Get-TestPowerShellExecutableNamesForCurrentEdition {
    if ([string]$PSVersionTable.PSEdition -eq "Desktop") {
        return @("powershell.exe", "powershell")
    }

    return @("pwsh.exe", "pwsh")
}

function Assert-TestPowerShellExecutableMatchesCurrentEdition {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = "Child PowerShell process"
    )

    $allowedNames = @(Get-TestPowerShellExecutableNamesForCurrentEdition)
    $actualName = [System.IO.Path]::GetFileName($Path)
    if ($allowedNames -notcontains $actualName) {
        throw "$Description resolved '$actualName', which does not match the parent PowerShell edition '$($PSVersionTable.PSEdition)'."
    }
}

function Get-TestPowerShellExecutable {
    # Keep child processes on the same PowerShell edition as the test runner.
    # In particular, a Windows PowerShell 5.1 CI run must not silently switch
    # its workers or temporary servers to an installed PowerShell 7 runtime.
    $allowedNames = @(Get-TestPowerShellExecutableNamesForCurrentEdition)

    try {
        $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
        try {
            $currentExecutable = [string]$currentProcess.MainModule.FileName
        }
        finally {
            $currentProcess.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($currentExecutable) -and
            $allowedNames -contains [System.IO.Path]::GetFileName($currentExecutable) -and
            (Test-Path -LiteralPath $currentExecutable -PathType Leaf)) {
            Assert-TestPowerShellExecutableMatchesCurrentEdition -Path $currentExecutable
            return $currentExecutable
        }
    }
    catch {
        # Fall back to the matching executable below when the host does not
        # expose its process module path.
    }

    foreach ($executableName in $allowedNames) {
        $psHomeCandidate = Join-Path -Path $PSHOME -ChildPath $executableName
        if (Test-Path -LiteralPath $psHomeCandidate -PathType Leaf) {
            Assert-TestPowerShellExecutableMatchesCurrentEdition -Path $psHomeCandidate
            return $psHomeCandidate
        }

        $command = Get-Command $executableName -ErrorAction SilentlyContinue
        if ($null -ne $command -and
            -not [string]::IsNullOrWhiteSpace([string]$command.Source) -and
            (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            $commandPath = [string]$command.Source
            Assert-TestPowerShellExecutableMatchesCurrentEdition -Path $commandPath
            return $commandPath
        }
    }

    throw "The current PowerShell runtime executable could not be resolved."
}
