param(
    [switch]$FailOnIssues
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..")).Path

$selfPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$targetFiles = Get-ChildItem -Path (Join-Path $repoRoot "apps"), (Join-Path $repoRoot "scripts") -Recurse -File -Include *.ps1, *.psd1 |
    Where-Object { [System.IO.Path]::GetFullPath($_.FullName) -ne $selfPath } |
    Sort-Object FullName

$checks = @(
    @{
        Name = "Ternary operator"
        Pattern = '(?m)\?.*:'
        Message = "PowerShell 7 ternary operator `?:` is not supported in Windows PowerShell 5.1."
    },
    @{
        Name = "Null coalescing"
        Pattern = '\?\?'
        Message = "PowerShell 7 null-coalescing operator `??` is not supported in Windows PowerShell 5.1."
    },
    @{
        Name = "Null conditional"
        Pattern = '\?\.'
        Message = "PowerShell 7 null-conditional operator `?.` is not supported in Windows PowerShell 5.1."
    },
    @{
        Name = "Pipeline chain"
        Pattern = '(?m)(?<!`)\&\&|(?<!`)\|\|'
        Message = "PowerShell 7 pipeline chain operators `&&` / `||` are not supported in Windows PowerShell 5.1."
    },
    @{
        Name = "Parallel foreach"
        Pattern = 'ForEach-Object\s+-Parallel|-Parallel\b'
        Message = "`ForEach-Object -Parallel` requires PowerShell 7."
    },
    @{
        Name = "ConvertFrom-Json AsHashtable"
        Pattern = 'ConvertFrom-Json\s+.*-AsHashtable'
        Message = "`ConvertFrom-Json -AsHashtable` requires PowerShell 6+."
    },
    @{
        Name = "ConvertTo-Json EnumsAsStrings"
        Pattern = 'ConvertTo-Json\s+.*-EnumsAsStrings'
        Message = "`ConvertTo-Json -EnumsAsStrings` requires PowerShell 6+."
    },
    @{
        Name = "Join-String"
        Pattern = '\bJoin-String\b'
        Message = "`Join-String` requires PowerShell 6.2+."
    },
    @{
        Name = "Get-Error"
        Pattern = '\bGet-Error\b'
        Message = "`Get-Error` requires PowerShell 7."
    },
    @{
        Name = "Test-Json"
        Pattern = '\bTest-Json\b'
        Message = "`Test-Json` requires PowerShell 6+."
    }
)

$issues = @()

foreach ($file in $targetFiles) {
    $content = Get-Content -Path $file.FullName -Raw

    foreach ($check in $checks) {
        $matches = [regex]::Matches($content, $check.Pattern)
        foreach ($match in $matches) {
            $prefix = $content.Substring(0, $match.Index)
            $lineNumber = ($prefix -split "`n").Count
            $issues += [PSCustomObject]@{
                File    = $file.FullName
                Line    = $lineNumber
                Check   = $check.Name
                Message = $check.Message
            }
        }
    }
}

if ($issues.Count -eq 0) {
    Write-Host "No obvious PowerShell 5.1 compatibility issues were found."
}
else {
    Write-Host "Potential PowerShell 5.1 compatibility issues:"
    foreach ($issue in $issues | Sort-Object File, Line, Check) {
        Write-Host ("- {0}:{1} [{2}] {3}" -f $issue.File, $issue.Line, $issue.Check, $issue.Message)
    }

    if ($FailOnIssues) {
        throw "PowerShell 5.1 compatibility audit found $($issues.Count) issue(s)."
    }
}
