function Get-EntryIdentifierValue {
    param($Entry)

    if ($null -eq $Entry) {
        return $null
    }

    if ($Entry.PSObject.Properties.Name -contains "entryId" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.entryId)) {
        return [string]$Entry.entryId
    }

    return $null
}

function Get-EntryExactPunchInText {
    param($Entry)

    if ($null -eq $Entry) {
        return $null
    }

    if ($Entry.PSObject.Properties.Name -contains "exactPunchIn" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.exactPunchIn)) {
        return [string]$Entry.exactPunchIn
    }

    if ($Entry.PSObject.Properties.Name -contains "punchIn" -and -not [string]::IsNullOrWhiteSpace([string]$Entry.punchIn)) {
        return [string]$Entry.punchIn
    }

    return $null
}

function Find-EntryIndex {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Entries,
        [string]$EntryId,
        [string]$Date,
        [string]$PunchIn
    )

    $entryList = @($Entries)
    if (-not [string]::IsNullOrWhiteSpace($EntryId)) {
        $matchingIndex = -1
        for ($i = 0; $i -lt $entryList.Count; $i++) {
            $storedEntryId = Get-EntryIdentifierValue -Entry $entryList[$i]
            if (-not [string]::IsNullOrWhiteSpace($storedEntryId) -and $storedEntryId -eq $EntryId) {
                if ($matchingIndex -ge 0) {
                    # Duplicate stable identifiers indicate damaged data. Fail
                    # closed instead of choosing an arbitrary record.
                    return -1
                }
                $matchingIndex = $i
            }
        }

        # Once a stable identifier is supplied, date/time metadata must never
        # redirect the mutation to a different entry.
        return $matchingIndex
    }

    $legacyMatchingIndex = -1
    for ($i = 0; $i -lt $entryList.Count; $i++) {
        $entry = $entryList[$i]
        if (-not [string]::IsNullOrWhiteSpace($Date) -and -not [string]::IsNullOrWhiteSpace($PunchIn)) {
            $exactPunchIn = Get-EntryExactPunchInText -Entry $entry
            if ([string]$entry.date -eq $Date -and ([string]$entry.punchIn -eq $PunchIn -or [string]$exactPunchIn -eq $PunchIn)) {
                if ($legacyMatchingIndex -ge 0) {
                    # Legacy date/time identifiers are only safe when unique.
                    return -1
                }
                $legacyMatchingIndex = $i
            }
        }
    }

    return $legacyMatchingIndex
}

function Get-EntryLegacyLookupKey {
    param(
        [string]$Date,
        [string]$PunchIn
    )

    if ([string]::IsNullOrWhiteSpace($Date) -or [string]::IsNullOrWhiteSpace($PunchIn)) {
        return ""
    }

    return ("{0}{1}{2}" -f $Date, [char]31, $PunchIn)
}

function New-EntryIndexLookup {
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Entries)

    $entryList = @($Entries)
    $byId = @{}
    $byDateAndPunch = @{}

    for ($i = 0; $i -lt $entryList.Count; $i++) {
        $entry = $entryList[$i]
        $entryId = Get-EntryIdentifierValue -Entry $entry
        if (-not [string]::IsNullOrWhiteSpace($entryId)) {
            if ($byId.ContainsKey($entryId)) {
                # A negative lookup value marks an ambiguous identifier.
                $byId[$entryId] = -1
            }
            else {
                $byId[$entryId] = $i
            }
        }

        $entryDate = [string]$entry.date
        if ([string]::IsNullOrWhiteSpace($entryDate)) {
            continue
        }

        $punchTimes = @([string]$entry.punchIn, [string](Get-EntryExactPunchInText -Entry $entry))
        foreach ($punchTime in $punchTimes) {
            $legacyKey = Get-EntryLegacyLookupKey -Date $entryDate -PunchIn $punchTime
            if (-not [string]::IsNullOrWhiteSpace($legacyKey)) {
                if ($byDateAndPunch.ContainsKey($legacyKey) -and [int]$byDateAndPunch[$legacyKey] -ne $i) {
                    $byDateAndPunch[$legacyKey] = -1
                }
                elseif (-not $byDateAndPunch.ContainsKey($legacyKey)) {
                    $byDateAndPunch[$legacyKey] = $i
                }
            }
        }
    }

    return [PSCustomObject]@{
        ById           = $byId
        ByDateAndPunch = $byDateAndPunch
    }
}

function Find-EntryIndexFromLookup {
    param(
        [Parameter(Mandatory = $true)]$Lookup,
        [string]$EntryId,
        [string]$Date,
        [string]$PunchIn
    )

    if (-not [string]::IsNullOrWhiteSpace($EntryId)) {
        if ($Lookup.ById.ContainsKey($EntryId)) {
            return [int]$Lookup.ById[$EntryId]
        }

        # Do not use mutable date/time fields as a fallback when the caller
        # supplied a stable ID: that could mutate a different record.
        return -1
    }

    $legacyKey = Get-EntryLegacyLookupKey -Date $Date -PunchIn $PunchIn
    if (-not [string]::IsNullOrWhiteSpace($legacyKey) -and $Lookup.ByDateAndPunch.ContainsKey($legacyKey)) {
        return [int]$Lookup.ByDateAndPunch[$legacyKey]
    }

    return -1
}

Export-ModuleMember -Function @(
    "Get-EntryIdentifierValue",
    "Get-EntryExactPunchInText",
    "Get-EntryLegacyLookupKey",
    "Find-EntryIndex",
    "New-EntryIndexLookup",
    "Find-EntryIndexFromLookup"
)
