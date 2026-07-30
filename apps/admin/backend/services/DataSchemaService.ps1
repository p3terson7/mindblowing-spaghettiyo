$script:SaphirDataFormatName = "SAPHIR"
$script:SaphirSupportedSchemaVersion = 1
$script:SaphirMinimumSchemaVersion = 1
$script:dataSchemaFile = Join-Path -Path $sharedFolder -ChildPath "data-schema.json"

function Read-SaphirDataSchemaFromDisk {
    if (-not (Test-Path -LiteralPath $script:dataSchemaFile -PathType Leaf)) {
        return $null
    }

    $raw = Read-TextFileCached -Path $script:dataSchemaFile
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw [System.IO.InvalidDataException]::new("SAPHIR data schema metadata is empty: $script:dataSchemaFile")
    }

    try {
        $schema = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw (New-Object System.IO.InvalidDataException(
            ("SAPHIR data schema metadata is invalid JSON: {0}" -f $script:dataSchemaFile),
            $_.Exception
        ))
    }

    if ($null -eq $schema -or
        ($schema -is [System.Collections.IEnumerable] -and -not ($schema -is [string]))) {
        throw [System.IO.InvalidDataException]::new("SAPHIR data schema metadata must be a JSON object: $script:dataSchemaFile")
    }

    return $schema
}

function Assert-SaphirDataSchemaCompatible {
    param([Parameter(Mandatory = $true)]$Schema)

    $format = if ($Schema.PSObject.Properties.Name -contains "format") { ([string]$Schema.format).Trim() } else { "" }
    if ($format -ne $script:SaphirDataFormatName) {
        throw [System.IO.InvalidDataException]::new("This folder does not contain recognized SAPHIR data schema metadata.")
    }

    $schemaVersion = 0
    if (-not ($Schema.PSObject.Properties.Name -contains "schemaVersion") -or
        -not [int]::TryParse([string]$Schema.schemaVersion, [ref]$schemaVersion) -or
        $schemaVersion -lt $script:SaphirMinimumSchemaVersion) {
        throw [System.IO.InvalidDataException]::new("The SAPHIR data schema version is missing or invalid.")
    }

    $minimumReaderVersion = $script:SaphirMinimumSchemaVersion
    if ($Schema.PSObject.Properties.Name -contains "minimumReaderVersion" -and
        (-not [int]::TryParse([string]$Schema.minimumReaderVersion, [ref]$minimumReaderVersion) -or
        $minimumReaderVersion -lt $script:SaphirMinimumSchemaVersion)) {
        throw [System.IO.InvalidDataException]::new("The SAPHIR minimum reader version is invalid.")
    }

    if ($schemaVersion -gt $script:SaphirSupportedSchemaVersion -or
        $minimumReaderVersion -gt $script:SaphirSupportedSchemaVersion) {
        throw [System.IO.InvalidDataException]::new(
            ("This data folder uses SAPHIR schema {0}, but this application supports only schema {1}. Install a compatible newer release; the folder was not modified." -f
                $schemaVersion,
                $script:SaphirSupportedSchemaVersion)
        )
    }

    return [PSCustomObject]@{
        format               = $format
        schemaVersion        = $schemaVersion
        minimumReaderVersion = $minimumReaderVersion
        createdAtUtc         = if ($Schema.PSObject.Properties.Name -contains "createdAtUtc") { [string]$Schema.createdAtUtc } else { "" }
    }
}

function Ensure-SaphirDataSchema {
    $schema = Read-SaphirDataSchemaFromDisk
    if ($null -ne $schema) {
        return (Assert-SaphirDataSchemaCompatible -Schema $schema)
    }

    $lockHandle = Acquire-ResourceLock -ResourcePath $script:dataSchemaFile
    try {
        $schema = Read-SaphirDataSchemaFromDisk
        if ($null -eq $schema) {
            $schema = [PSCustomObject]@{
                format               = $script:SaphirDataFormatName
                schemaVersion        = $script:SaphirSupportedSchemaVersion
                minimumReaderVersion = $script:SaphirMinimumSchemaVersion
                createdAtUtc         = (Get-Date).ToUniversalTime().ToString("o")
            }
            Write-JsonAtomic -Path $script:dataSchemaFile -Value $schema -Depth 4
        }
    }
    finally {
        Release-ResourceLock -LockHandle $lockHandle
    }

    return (Assert-SaphirDataSchemaCompatible -Schema $schema)
}
