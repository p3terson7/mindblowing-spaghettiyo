$ErrorActionPreference = "Stop"

function New-TestOrdinalHashtable {
    # PowerShell literal hashtables compare string keys without regard to case.
    # DATA contracts must keep JSON paths such as `status` and `Status` distinct.
    return (New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal))
}

function Get-TestNormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    while ($fullPath.Length -gt $pathRoot.Length -and
        ($fullPath.EndsWith([string][System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal) -or
        $fullPath.EndsWith([string][System.IO.Path]::AltDirectorySeparatorChar, [System.StringComparison]::Ordinal))) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath
}

function Test-TestPathIsEqualOrDescendant {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AncestorPath
    )

    $resolvedPath = Get-TestNormalizedFullPath -Path $Path
    $resolvedAncestor = Get-TestNormalizedFullPath -Path $AncestorPath
    if ([string]::Equals($resolvedPath, $resolvedAncestor, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $ancestorPrefix = $resolvedAncestor
    if (-not ($ancestorPrefix.EndsWith([string][System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal) -or
        $ancestorPrefix.EndsWith([string][System.IO.Path]::AltDirectorySeparatorChar, [System.StringComparison]::Ordinal))) {
        $ancestorPrefix += [System.IO.Path]::DirectorySeparatorChar
    }
    return $resolvedPath.StartsWith($ancestorPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-TestOrdinalUniqueStrings {
    param([AllowEmptyCollection()][string[]]$Values = @())

    $set = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($value in @($Values)) {
        [void]$set.Add([string]$value)
    }
    return @($set)
}

function Get-TestFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "")
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-TestDataFolderSnapshot {
    <#
        Captures every file below an isolated DATA fixture. The snapshot keeps
        the original text so JSON changes can later be checked at leaf level.
        This helper deliberately refuses the repository's production DATA path;
        phase-zero tests must always operate on disposable copies.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [string]$ForbiddenRootPath = ""
    )

    $resolvedRoot = Get-TestNormalizedFullPath -Path $RootPath

    if (-not [string]::IsNullOrWhiteSpace($ForbiddenRootPath)) {
        $resolvedForbiddenRoot = Get-TestNormalizedFullPath -Path $ForbiddenRootPath
        # Check the boundary before Test-Path/Get-ChildItem so neither the real
        # DATA directory nor any descendant is ever probed by mutation tests.
        if (Test-TestPathIsEqualOrDescendant -Path $resolvedRoot -AncestorPath $resolvedForbiddenRoot) {
            throw "Phase-zero mutation tests cannot use the repository DATA folder."
        }
    }

    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "Test DATA folder was not found: $resolvedRoot"
    }

    $files = New-TestOrdinalHashtable
    foreach ($file in @(Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -ErrorAction Stop | Sort-Object FullName)) {
        $relativePath = $file.FullName.Substring($resolvedRoot.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ).Replace([System.IO.Path]::DirectorySeparatorChar, "/")
        $text = $null
        if ($file.Extension -ieq ".json") {
            $text = [System.IO.File]::ReadAllText($file.FullName)
        }
        $files[$relativePath] = [PSCustomObject]@{
            RelativePath = $relativePath
            Sha256       = Get-TestFileSha256 -Path $file.FullName
            JsonText     = $text
        }
    }

    return [PSCustomObject]@{
        RootPath = $resolvedRoot
        Files    = $files
    }
}

function Add-TestJsonLeaves {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Leaves
    )

    if ($null -eq $Value) {
        $Leaves[$Path] = "null"
        return
    }

    if ($Value -is [string] -or $Value -is [char] -or
        $Value -is [bool] -or $Value -is [byte] -or
        $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or
        $Value -is [uint32] -or $Value -is [int64] -or
        $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [datetime]) {
        $typeName = $Value.GetType().FullName
        $Leaves[$Path] = "${typeName}:$(ConvertTo-Json -InputObject $Value -Compress)"
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        if ($keys.Count -eq 0) {
            $Leaves[$Path] = "{empty-object}"
            return
        }
        foreach ($key in $keys) {
            Add-TestJsonLeaves -Value $Value[$key] -Path ("{0}.{1}" -f $Path, $key) -Leaves $Leaves
        }
        return
    }

    if ($Value.PSObject.TypeNames -contains "System.Management.Automation.PSCustomObject") {
        $properties = @($Value.PSObject.Properties | Sort-Object Name)
        if ($properties.Count -eq 0) {
            $Leaves[$Path] = "{empty-object}"
            return
        }
        foreach ($property in $properties) {
            Add-TestJsonLeaves -Value $property.Value -Path ("{0}.{1}" -f $Path, $property.Name) -Leaves $Leaves
        }
        return
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            $Leaves[$Path] = "[empty-array]"
            return
        }
        for ($index = 0; $index -lt $items.Count; $index++) {
            Add-TestJsonLeaves -Value $items[$index] -Path ("{0}[{1}]" -f $Path, $index) -Leaves $Leaves
        }
        return
    }

    $Leaves[$Path] = "unknown:$([string]$Value)"
}

function Get-TestJsonLeafMap {
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        throw "Changed JSON file is empty: $RelativePath"
    }

    $trimmedJson = $JsonText.Trim()
    if ($trimmedJson -eq "[]") {
        return @{ '$' = "[empty-array]" }
    }
    if ($trimmedJson -eq "{}") {
        return @{ '$' = "{empty-object}" }
    }

    try {
        $value = ConvertFrom-Json -InputObject $JsonText -ErrorAction Stop
    }
    catch {
        throw "Changed file is not valid JSON: $RelativePath. $($_.Exception.Message)"
    }

    $leaves = New-TestOrdinalHashtable
    if ($trimmedJson.StartsWith("[")) {
        # Windows PowerShell 5.1 enumerates a one-item root array returned by
        # ConvertFrom-Json. Preserve the JSON root shape explicitly so paths
        # remain `$[0].field` on every supported host.
        $items = @($value)
        for ($index = 0; $index -lt $items.Count; $index++) {
            Add-TestJsonLeaves -Value $items[$index] -Path ("`$[{0}]" -f $index) -Leaves $leaves
        }
    }
    else {
        Add-TestJsonLeaves -Value $value -Path '$' -Leaves $leaves
    }
    return $leaves
}

function Test-TestJsonPathAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$AllowedPatterns
    )

    foreach ($patternValue in @($AllowedPatterns)) {
        $pattern = [string]$patternValue
        $regex = [System.Text.RegularExpressions.Regex]::Escape($pattern)
        $regex = $regex.Replace("\{index}", "[0-9]+")
        $regex = $regex.Replace("\*", ".*")
        if ([System.Text.RegularExpressions.Regex]::IsMatch(
            $Path,
            ("^{0}$" -f $regex),
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        )) {
            return $true
        }
    }
    return $false
}

function Get-TestChangedJsonPaths {
    param(
        [Parameter(Mandatory = $true)]$BeforeFile,
        [Parameter(Mandatory = $true)]$AfterFile
    )

    $beforeLeaves = Get-TestJsonLeafMap -JsonText ([string]$BeforeFile.JsonText) -RelativePath ([string]$BeforeFile.RelativePath)
    $afterLeaves = Get-TestJsonLeafMap -JsonText ([string]$AfterFile.JsonText) -RelativePath ([string]$AfterFile.RelativePath)
    $allPaths = @(Get-TestOrdinalUniqueStrings -Values @($beforeLeaves.Keys + $afterLeaves.Keys))
    $changed = New-Object System.Collections.ArrayList
    foreach ($path in $allPaths) {
        $beforeContains = $beforeLeaves.ContainsKey($path)
        $afterContains = $afterLeaves.ContainsKey($path)
        if ($beforeContains -and -not $afterContains -and
            @("[empty-array]", "{empty-object}") -contains [string]$beforeLeaves[$path] -and
            @($afterLeaves.Keys | Where-Object {
                $_.StartsWith("$path.", [System.StringComparison]::Ordinal) -or
                $_.StartsWith("$path[", [System.StringComparison]::Ordinal)
            }).Count -gt 0) {
            # Expanding an empty container is fully described by the new child
            # leaves. Do not require callers to allow an otherwise meaningless
            # root-marker removal in addition to those precise child paths.
            continue
        }
        if (-not $beforeContains -or -not $afterContains -or
            -not [string]::Equals(
                [string]$beforeLeaves[$path],
                [string]$afterLeaves[$path],
                [System.StringComparison]::Ordinal
            )) {
            [void]$changed.Add($path)
        }
    }
    return @($changed.ToArray())
}

function Assert-TestDataFolderChanges {
    <#
        AllowedChanges maps a relative JSON filename to allowed leaf paths.
        Patterns support `{index}` for an array index and `*` for the remainder:
          "history.json" = @('$[{index}].*')
          "000100001_data.json" = @('$[{index}].status')
    #>
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After,
        [System.Collections.IDictionary]$AllowedChanges = @{},
        [string]$Description = "DATA mutation"
    )

    $beforeFiles = $Before.Files
    $afterFiles = $After.Files
    $ordinalAllowedChanges = New-TestOrdinalHashtable
    foreach ($allowedFile in @($AllowedChanges.Keys)) {
        $ordinalAllowedChanges[[string]$allowedFile] = $AllowedChanges[$allowedFile]
    }
    $allFiles = @(Get-TestOrdinalUniqueStrings -Values @($beforeFiles.Keys + $afterFiles.Keys))
    $changedFiles = New-Object System.Collections.ArrayList

    foreach ($relativePath in $allFiles) {
        $beforeContains = $beforeFiles.ContainsKey($relativePath)
        $afterContains = $afterFiles.ContainsKey($relativePath)
        if ($beforeContains -and $afterContains -and
            [string]$beforeFiles[$relativePath].Sha256 -eq [string]$afterFiles[$relativePath].Sha256) {
            continue
        }

        [void]$changedFiles.Add($relativePath)
        if (-not $ordinalAllowedChanges.ContainsKey($relativePath)) {
            throw "$Description changed an unexpected file: $relativePath"
        }
        if (-not $beforeContains -or -not $afterContains) {
            throw "$Description unexpectedly created or deleted '$relativePath'. File-set changes require a dedicated contract."
        }
        if ([string]::IsNullOrWhiteSpace([string]$beforeFiles[$relativePath].JsonText) -or
            [string]::IsNullOrWhiteSpace([string]$afterFiles[$relativePath].JsonText)) {
            throw "$Description changed non-JSON content in '$relativePath'."
        }

        $changedPaths = @(Get-TestChangedJsonPaths -BeforeFile $beforeFiles[$relativePath] -AfterFile $afterFiles[$relativePath])
        if ($changedPaths.Count -eq 0) {
            throw "$Description rewrote '$relativePath' without a semantic JSON change."
        }
        foreach ($changedPath in $changedPaths) {
            if (-not (Test-TestJsonPathAllowed -Path $changedPath -AllowedPatterns $ordinalAllowedChanges[$relativePath])) {
                throw "$Description changed unexpected JSON path '$changedPath' in '$relativePath'."
            }
        }
    }

    return @($changedFiles.ToArray())
}

function Assert-TestDataFolderUnchanged {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After,
        [string]$Description = "Read-only operation"
    )

    $changes = @(Assert-TestDataFolderChanges -Before $Before -After $After -AllowedChanges @{} -Description $Description)
    if ($changes.Count -ne 0) {
        throw "$Description unexpectedly changed DATA."
    }
}
