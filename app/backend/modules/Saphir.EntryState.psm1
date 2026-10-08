function ConvertTo-BooleanFlag {
    param($Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($null -eq $Value) {
        return $false
    }

    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    return ($normalized -eq "true" -or $normalized -eq "1" -or $normalized -eq "yes")
}

function Test-EntryForgottenClockOut {
    param($Entry)

    if ($null -eq $Entry) {
        return $false
    }

    $forgottenFlag = $false
    $reviewFlag = $false

    if ($Entry.PSObject.Properties.Name -contains "forgottenClockOut") {
        $forgottenFlag = ConvertTo-BooleanFlag -Value $Entry.forgottenClockOut
    }

    if ($Entry.PSObject.Properties.Name -contains "needsClockOutReview") {
        $reviewFlag = ConvertTo-BooleanFlag -Value $Entry.needsClockOutReview
    }

    return ($forgottenFlag -or $reviewFlag)
}

function Test-EntryOpen {
    param($Entry)

    return ($null -ne $Entry -and
        -not (Test-EntryForgottenClockOut -Entry $Entry) -and
        -not [string]::IsNullOrWhiteSpace([string]$Entry.punchIn) -and
        [string]::IsNullOrWhiteSpace([string]$Entry.punchOut))
}

Export-ModuleMember -Function @(
    "ConvertTo-BooleanFlag",
    "Test-EntryForgottenClockOut",
    "Test-EntryOpen"
)
