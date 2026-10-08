param(
    [switch]$FailOnIssues
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../..")).Path

$selfPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$targetRoots = @(
    (Join-Path -Path $repoRoot -ChildPath "app"),
    (Join-Path -Path $repoRoot -ChildPath "scripts"),
    (Join-Path -Path $repoRoot -ChildPath "tests/powershell")
)
$targetFiles = Get-ChildItem -LiteralPath $targetRoots -Recurse -File |
    Where-Object {
        $_.Extension -in @(".ps1", ".psd1", ".psm1") -and
        [System.IO.Path]::GetFullPath($_.FullName) -ne $selfPath
    } |
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

function Set-AnalysisCharacterRange {
    param(
        [Parameter(Mandatory = $true)]
        [char[]]$Characters,

        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [int]$StartOffset,

        [Parameter(Mandatory = $true)]
        [int]$EndOffset,

        [switch]$Restore
    )

    $safeStart = [Math]::Max(0, $StartOffset)
    $safeEnd = [Math]::Min($Characters.Length, $EndOffset)
    for ($characterIndex = $safeStart; $characterIndex -lt $safeEnd; $characterIndex++) {
        if ($Characters[$characterIndex] -eq "`r" -or $Characters[$characterIndex] -eq "`n") {
            continue
        }

        if ($Restore) {
            $Characters[$characterIndex] = $Source[$characterIndex]
        }
        else {
            $Characters[$characterIndex] = " "
        }
    }
}

function Restore-ExpandableStringExpressions {
    param(
        [Parameter(Mandatory = $true)]
        $Token,

        [Parameter(Mandatory = $true)]
        [char[]]$Characters,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $nestedTokensProperty = $Token.PSObject.Properties["NestedTokens"]
    if ($null -eq $nestedTokensProperty) {
        return
    }

    foreach ($nestedToken in @($nestedTokensProperty.Value)) {
        $nestedKind = [string]$nestedToken.Kind
        if ($nestedKind -in @("Comment", "StringLiteral", "HereStringLiteral")) {
            continue
        }

        if ($nestedKind -in @("StringExpandable", "HereStringExpandable")) {
            Restore-ExpandableStringExpressions -Token $nestedToken -Characters $Characters -Source $Source
            continue
        }

        Set-AnalysisCharacterRange -Characters $Characters -Source $Source -StartOffset $nestedToken.Extent.StartOffset -EndOffset $nestedToken.Extent.EndOffset -Restore
    }
}

function Get-PowerShellAuditResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [object[]]$CompatibilityChecks
    )

    # Compatibility operators embedded in HTML/JavaScript templates are data,
    # not PowerShell syntax. Mask strings and comments while preserving line
    # breaks so the regex audit reports only executable PowerShell tokens.
    # Expandable strings need special handling: their literal text is data, but
    # the tokens inside $() are executable PowerShell and must remain visible.
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$parseErrors) | Out-Null

    $analysisCharacters = $Content.ToCharArray()
    foreach ($token in @($tokens)) {
        $tokenKind = [string]$token.Kind
        if ($tokenKind -in @("Comment", "StringLiteral", "HereStringLiteral")) {
            Set-AnalysisCharacterRange -Characters $analysisCharacters -Source $Content -StartOffset $token.Extent.StartOffset -EndOffset $token.Extent.EndOffset
            continue
        }

        if ($tokenKind -in @("StringExpandable", "HereStringExpandable")) {
            Set-AnalysisCharacterRange -Characters $analysisCharacters -Source $Content -StartOffset $token.Extent.StartOffset -EndOffset $token.Extent.EndOffset
            Restore-ExpandableStringExpressions -Token $token -Characters $analysisCharacters -Source $Content
        }
    }
    $analysisContent = -join $analysisCharacters

    $resultIssues = @()
    foreach ($parseError in @($parseErrors)) {
        $lineNumber = [Math]::Max(1, [int]$parseError.Extent.StartLineNumber)
        $errorIdentifier = [string]$parseError.ErrorId
        if ([string]::IsNullOrWhiteSpace($errorIdentifier)) {
            $errorIdentifier = "ParserError"
        }

        $resultIssues += [PSCustomObject]@{
            File    = $FilePath
            Line    = $lineNumber
            Check   = "Parser error"
            Message = "PowerShell parser error ($errorIdentifier): $($parseError.Message)"
        }
    }

    foreach ($check in $CompatibilityChecks) {
        $matches = [regex]::Matches($analysisContent, $check.Pattern)
        foreach ($match in $matches) {
            $prefix = $analysisContent.Substring(0, $match.Index)
            $lineNumber = ($prefix -split "`n").Count
            $resultIssues += [PSCustomObject]@{
                File    = $FilePath
                Line    = $lineNumber
                Check   = $check.Name
                Message = $check.Message
            }
        }
    }

    return $resultIssues
}

function Assert-AuditSelfTest {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$CompatibilityChecks
    )

    $templateSample = @'
$page = @"
<script>
const fallback = selected ?? defaultValue;
const ready = first && second;
const label = ready ? "yes" : "no";
const nested = employee?.name;
// Join-String and Get-Error are JavaScript/template text here.
</script>
"@
'@
    $templateIssues = @(Get-PowerShellAuditResult -Content $templateSample -FilePath "<self-test-template>" -CompatibilityChecks $CompatibilityChecks)
    if ($templateIssues.Count -ne 0) {
        throw "PowerShell 5.1 audit self-test failed: template/string content produced $($templateIssues.Count) false positive(s)."
    }

    # Use syntax that both Windows PowerShell 5.1 and PowerShell 7 can parse so
    # this verifies nested-token restoration independently of parser recovery.
    $executableSample = '$value = "$(& Join-String)"'
    $executableIssues = @(Get-PowerShellAuditResult -Content $executableSample -FilePath "<self-test-executable>" -CompatibilityChecks $CompatibilityChecks)
    if (@($executableIssues | Where-Object { $_.Check -eq "Join-String" }).Count -ne 1) {
        throw "PowerShell 5.1 audit self-test failed: executable syntax inside an expandable string was not detected."
    }

    $invalidSample = '$value = ('
    $invalidIssues = @(Get-PowerShellAuditResult -Content $invalidSample -FilePath "<self-test-parser>" -CompatibilityChecks $CompatibilityChecks)
    if (@($invalidIssues | Where-Object { $_.Check -eq "Parser error" }).Count -eq 0) {
        throw "PowerShell 5.1 audit self-test failed: a deterministic parser error was not reported."
    }
}

Assert-AuditSelfTest -CompatibilityChecks $checks

$issues = @()

foreach ($file in $targetFiles) {
    $content = Get-Content -Path $file.FullName -Raw
    $issues += @(Get-PowerShellAuditResult -Content $content -FilePath $file.FullName -CompatibilityChecks $checks)
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
