Set-StrictMode -Version 2.0

$script:BugReportCategories = @('bug', 'performance', 'visual', 'data', 'suggestion', 'other')
$script:BugReportStatuses = @('new', 'acknowledged', 'inProgress', 'waitingForUser', 'resolved', 'closed')
$script:BugReportPriorities = @('unranked', 'p1', 'p2', 'p3', 'p4')
$script:BugReportContentFields = @('title', 'description', 'category', 'stepsToReproduce', 'expectedBehavior', 'actualBehavior', 'technicalContext')
$script:BugReportAdministrativeFields = @('status', 'priority', 'rank')

function Get-SaphirBugReportProperty {
    param($Value, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    if ($Value.PSObject.Properties.Name -contains $Name) {
        return $Value.PSObject.Properties[$Name].Value
    }
    return $null
}

function Test-SaphirBugReportHasProperty {
    param($Value, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Contains($Name) }
    return ($Value.PSObject.Properties.Name -contains $Name)
}

function ConvertTo-SaphirBugReportText {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int]$MaximumLength,
        [bool]$Required = $false
    )

    $text = ([string]$Value).Trim()
    if ($Required -and [string]::IsNullOrWhiteSpace($text)) {
        throw [System.ArgumentException]::new("$Label is required.")
    }
    if ($text.Length -gt $MaximumLength) {
        throw [System.ArgumentException]::new("$Label cannot exceed $MaximumLength characters.")
    }
    return $text
}

function ConvertTo-SaphirBugReportChoice {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$AllowedValues
    )

    $text = ([string]$Value).Trim()
    foreach ($allowedValue in $AllowedValues) {
        if ($text.Equals($allowedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $allowedValue
        }
    }
    throw [System.ArgumentException]::new(("{0} must be one of: {1}." -f $Label, ($AllowedValues -join ', ')))
}

function ConvertTo-SaphirBugReportTechnicalContext {
    param($Value)

    $context = [ordered]@{}
    foreach ($field in @(
        @{ Name = 'appVersion'; MaximumLength = 100 },
        @{ Name = 'page'; MaximumLength = 300 },
        @{ Name = 'browser'; MaximumLength = 500 },
        @{ Name = 'operatingSystem'; MaximumLength = 300 },
        @{ Name = 'language'; MaximumLength = 50 }
    )) {
        $fieldName = [string]$field.Name
        if (Test-SaphirBugReportHasProperty -Value $Value -Name $fieldName) {
            $context[$fieldName] = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty -Value $Value -Name $fieldName) -Label $fieldName -MaximumLength ([int]$field.MaximumLength)
        }
        else {
            $context[$fieldName] = ''
        }
    }
    return [PSCustomObject]$context
}

function ConvertTo-SaphirBugReportCreateInput {
    param([Parameter(Mandatory = $true)]$Value)

    return [PSCustomObject][ordered]@{
        title              = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty -Value $Value -Name 'title') -Label 'Title' -MaximumLength 160 -Required:$true
        description        = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty -Value $Value -Name 'description') -Label 'Description' -MaximumLength 5000 -Required:$true
        category           = ConvertTo-SaphirBugReportChoice -Value (Get-SaphirBugReportProperty -Value $Value -Name 'category') -Label 'Category' -AllowedValues $script:BugReportCategories
        stepsToReproduce   = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty -Value $Value -Name 'stepsToReproduce') -Label 'Steps to reproduce' -MaximumLength 5000
        expectedBehavior   = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty -Value $Value -Name 'expectedBehavior') -Label 'Expected behavior' -MaximumLength 3000
        actualBehavior     = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty -Value $Value -Name 'actualBehavior') -Label 'Actual behavior' -MaximumLength 3000
        technicalContext   = ConvertTo-SaphirBugReportTechnicalContext -Value (Get-SaphirBugReportProperty -Value $Value -Name 'technicalContext')
    }
}

function ConvertTo-SaphirBugReportCommentInput {
    param([Parameter(Mandatory = $true)]$Value)

    return [PSCustomObject][ordered]@{
        body = ConvertTo-SaphirBugReportText `
            -Value (Get-SaphirBugReportProperty -Value $Value -Name 'body') `
            -Label 'Comment' `
            -MaximumLength 3000 `
            -Required:$true
    }
}

function ConvertTo-SaphirBugReportPatchInput {
    param([Parameter(Mandatory = $true)]$Value)

    $fields = [ordered]@{}
    $contentFieldNames = New-Object System.Collections.ArrayList
    $administrativeFieldNames = New-Object System.Collections.ArrayList

    foreach ($fieldName in $script:BugReportContentFields) {
        if (-not (Test-SaphirBugReportHasProperty -Value $Value -Name $fieldName)) { continue }
        switch ($fieldName) {
            'title' { $fields[$fieldName] = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty $Value $fieldName) -Label 'Title' -MaximumLength 160 -Required:$true }
            'description' { $fields[$fieldName] = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty $Value $fieldName) -Label 'Description' -MaximumLength 5000 -Required:$true }
            'category' { $fields[$fieldName] = ConvertTo-SaphirBugReportChoice -Value (Get-SaphirBugReportProperty $Value $fieldName) -Label 'Category' -AllowedValues $script:BugReportCategories }
            'stepsToReproduce' { $fields[$fieldName] = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty $Value $fieldName) -Label 'Steps to reproduce' -MaximumLength 5000 }
            'expectedBehavior' { $fields[$fieldName] = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty $Value $fieldName) -Label 'Expected behavior' -MaximumLength 3000 }
            'actualBehavior' { $fields[$fieldName] = ConvertTo-SaphirBugReportText -Value (Get-SaphirBugReportProperty $Value $fieldName) -Label 'Actual behavior' -MaximumLength 3000 }
            'technicalContext' { $fields[$fieldName] = ConvertTo-SaphirBugReportTechnicalContext -Value (Get-SaphirBugReportProperty $Value $fieldName) }
        }
        [void]$contentFieldNames.Add($fieldName)
    }

    foreach ($fieldName in $script:BugReportAdministrativeFields) {
        if (-not (Test-SaphirBugReportHasProperty -Value $Value -Name $fieldName)) { continue }
        switch ($fieldName) {
            'status' { $fields[$fieldName] = ConvertTo-SaphirBugReportChoice -Value (Get-SaphirBugReportProperty $Value $fieldName) -Label 'Status' -AllowedValues $script:BugReportStatuses }
            'priority' { $fields[$fieldName] = ConvertTo-SaphirBugReportChoice -Value (Get-SaphirBugReportProperty $Value $fieldName) -Label 'Priority' -AllowedValues $script:BugReportPriorities }
            'rank' {
                $rank = 0L
                if (-not [Int64]::TryParse([string](Get-SaphirBugReportProperty $Value $fieldName), [ref]$rank) -or $rank -lt 0 -or $rank -gt 2147483647) {
                    throw [System.ArgumentException]::new('Rank must be an integer between 0 and 2147483647.')
                }
                $fields[$fieldName] = $rank
            }
        }
        [void]$administrativeFieldNames.Add($fieldName)
    }

    if ($fields.Count -eq 0) {
        throw [System.ArgumentException]::new('At least one editable bug-report field is required.')
    }

    return [PSCustomObject][ordered]@{
        fields                   = [PSCustomObject]$fields
        fieldNames               = @($fields.Keys)
        contentFieldNames        = @($contentFieldNames.ToArray())
        administrativeFieldNames = @($administrativeFieldNames.ToArray())
    }
}

function Get-SaphirBugReportUserRole {
    param($User)
    return ([string](Get-SaphirBugReportProperty -Value $User -Name 'role')).Trim()
}

function Get-SaphirBugReportUsername {
    param($User)
    return ([string](Get-SaphirBugReportProperty -Value $User -Name 'username')).Trim()
}

function Get-SaphirBugReportReporterUsername {
    param($Report)
    $createdBy = Get-SaphirBugReportProperty -Value $Report -Name 'createdBy'
    return ([string](Get-SaphirBugReportProperty -Value $createdBy -Name 'username')).Trim()
}

function Test-SaphirBugReportAdministrativeUser {
    param($User)
    return (Get-SaphirBugReportUserRole -User $User).Equals('superAdmin', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SaphirBugReportVisible {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)]$User
    )

    $role = Get-SaphirBugReportUserRole -User $User
    if ($role.Equals('admin', [System.StringComparison]::OrdinalIgnoreCase) -or
        $role.Equals('superAdmin', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $username = Get-SaphirBugReportUsername -User $User
    return (-not [string]::IsNullOrWhiteSpace($username) -and
        $username.Equals((Get-SaphirBugReportReporterUsername -Report $Report), [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-SaphirBugReportReporterEditAllowed {
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)]$User
    )

    $username = Get-SaphirBugReportUsername -User $User
    $status = ([string](Get-SaphirBugReportProperty -Value $Report -Name 'status')).Trim()
    return (-not [string]::IsNullOrWhiteSpace($username) -and
        $username.Equals((Get-SaphirBugReportReporterUsername -Report $Report), [System.StringComparison]::OrdinalIgnoreCase) -and
        $status.Equals('new', [System.StringComparison]::OrdinalIgnoreCase))
}

function New-SaphirBugReportSummary {
    param([Parameter(Mandatory = $true)]$Report)

    $description = [string](Get-SaphirBugReportProperty -Value $Report -Name 'description')
    $preview = if ($description.Length -gt 240) { $description.Substring(0, 237) + '...' } else { $description }
    $attachments = @(Get-SaphirBugReportProperty -Value $Report -Name 'attachments')
    $comments = @(Get-SaphirBugReportProperty -Value $Report -Name 'comments')
    return [PSCustomObject][ordered]@{
        reportId          = [string](Get-SaphirBugReportProperty $Report 'reportId')
        revision          = [int](Get-SaphirBugReportProperty $Report 'revision')
        title             = [string](Get-SaphirBugReportProperty $Report 'title')
        descriptionPreview = $preview
        category          = [string](Get-SaphirBugReportProperty $Report 'category')
        status            = [string](Get-SaphirBugReportProperty $Report 'status')
        priority          = [string](Get-SaphirBugReportProperty $Report 'priority')
        rank              = [Int64](Get-SaphirBugReportProperty $Report 'rank')
        createdBy         = Get-SaphirBugReportProperty $Report 'createdBy'
        createdAtUtc      = [string](Get-SaphirBugReportProperty $Report 'createdAtUtc')
        updatedAtUtc      = [string](Get-SaphirBugReportProperty $Report 'updatedAtUtc')
        attachmentCount   = $attachments.Count
        commentCount      = $comments.Count
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-SaphirBugReportCreateInput',
    'ConvertTo-SaphirBugReportCommentInput',
    'ConvertTo-SaphirBugReportPatchInput',
    'Test-SaphirBugReportVisible',
    'Test-SaphirBugReportReporterEditAllowed',
    'Test-SaphirBugReportAdministrativeUser',
    'New-SaphirBugReportSummary'
)
