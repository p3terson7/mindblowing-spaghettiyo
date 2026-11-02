$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sourcePath = Join-Path $repo 'scripts/saphir-launcher.ps1'
$source = [IO.File]::ReadAllText($sourcePath)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
function Assert-Compact($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
Assert-Compact ($errors.Count -eq 0) 'Launcher PowerShell does not parse.'
foreach ($functionName in @('Get-LauncherThemePalette', 'Apply-Status', 'Show-Error', 'Hide-Error', 'Set-CheckingPresentation')) {
    $node = $ast.Find({ param($candidate) $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $functionName }, $true)
    Assert-Compact ($null -ne $node) "Missing launcher presentation helper: $functionName"
    . ([scriptblock]::Create($node.Extent.Text))
}
# The actual presentation code is exercised with plain controls on every OS;
# process management remains covered by test-saphir-launcher-control.ps1.
function New-Brush([string]$Color) { return $Color }
function Set-Visible($Element, [bool]$Visible) { $Element.Visible = $Visible }
function Get-DeploymentIssueMessage($Status) { return $script:deploymentMessage }
$textNode = $ast.Find({ param($candidate) $candidate -is [System.Management.Automation.Language.AssignmentStatementAst] -and $candidate.Left.Extent.Text -eq '$text' }, $true)
$xamlText = [regex]::Match($source, "(?s)\[xml\]\`$xaml\s*=\s*@'\r?\n(?<xaml>.*?)\r?\n'@").Groups['xaml'].Value
[xml]$xaml = $xamlText
$ns = New-Object Xml.XmlNamespaceManager($xaml.NameTable)
$ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
$ns.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$named = @($xaml.SelectNodes('//*[@x:Name]', $ns))
Assert-Compact ($xaml.SelectSingleNode('//w:Image[@x:Name="BrandLogo"]', $ns).Width -eq '46') 'Launcher must display the real logo, not a letter placeholder.'
Assert-Compact ($xaml.SelectSingleNode('//w:Expander[@x:Name="TechnicalDetailsExpander"]', $ns).IsExpanded -eq 'False') 'Technical paths must start collapsed.'
Assert-Compact ($null -ne $xaml.SelectSingleNode('//w:ScrollViewer[@VerticalScrollBarVisibility="Auto"]', $ns)) 'Small displays must be able to reach every action.'
Assert-Compact ($xamlText -notmatch 'Text="S"|Width="88"|Height="58"') 'Old letter logo or oversized maintenance tiles remain.'
Assert-Compact ($source -match 'BitmapCacheOption\]::OnLoad' -and $source -match '\$imageStream.Dispose\(\)') 'Logo loading must release the local file handle.'

foreach ($appearance in @('Dark', 'Light')) {
    $script:launcherPalette = Get-LauncherThemePalette $appearance
    $resources = @($xaml.SelectNodes('//w:Window.Resources/w:SolidColorBrush', $ns))
    foreach ($resource in $resources) { Assert-Compact ($script:launcherPalette.ContainsKey($resource.GetAttribute('Key', $ns.LookupNamespace('x')))) 'Theme is missing a brush.' }
    foreach ($isFrench in @($true, $false)) {
        $text = & ([scriptblock]::Create($textNode.Right.Extent.Text))
        foreach ($element in $named) {
            $name = $element.GetAttribute('Name', $ns.LookupNamespace('x'))
            Set-Variable -Scope Script -Name $name -Value ([PSCustomObject]@{ Text = ''; Content = ''; ToolTip = $null; Foreground = ''; Background = ''; BorderBrush = ''; Fill = ''; Visible = $false; IsEnabled = $false; IsDefault = $false })
        }
        $script:actionBusy = $false; $script:errorKind = ''; $script:deploymentMessage = ''
        Set-CheckingPresentation
        Assert-Compact ($script:StateTitle.Text -eq $text.Checking -and -not $script:OpenButton.Visible) 'Initial checking state exposed an action too early.'
        $status = [PSCustomObject]@{
            State = 'Online'; CanStart = $false; CanOpen = $true; CanRestart = $true; CanStop = $true; CanUpdate = $false; CanRepair = $true
            DataFolderPath = 'R:\SAPHIR\DATA'; DataAvailable = $true; DistributionRoot = 'R:\SAPHIR-Distribution'; DistributionReachable = $true; DistributionAvailable = $true
            DeploymentState = 'Ready'; TargetPreviouslyFailed = $false; UpdateAvailable = $false; FrontendUrl = 'http://localhost:8081/'
            ReleaseId = 'desktop-20261016-123456789-long-identifier'; TargetReleaseId = 'desktop-20261016-123456789-long-identifier'
        }
        Apply-Status $status
        Assert-Compact ($script:StateTitle.Text -eq $text.ReadyTitle -and $script:OpenButton.Visible -and $script:OpenButton.IsEnabled) 'Online state did not preserve the Open action.'
        Assert-Compact (-not $script:StartButton.Visible -and -not $script:UpdateButton.Visible) 'Online state showed duplicate primary actions.'
        Assert-Compact ($script:ReleaseValue.ToolTip -eq $status.ReleaseId -and $script:TargetReleaseValue.Text -eq $status.TargetReleaseId) 'Full release IDs were lost or redundant status was embedded in the version.'
        Assert-Compact ($script:LastCheckedText.Text -match '\d{2}:\d{2}') 'Status checks must update the timestamp.'
        $status.State = 'Offline'; $status.CanOpen = $false; $status.CanStart = $true; $status.CanStop = $false; $status.CanRestart = $false
        Apply-Status $status
        Assert-Compact ($script:StartButton.Visible -and $script:StartButton.IsDefault -and -not $script:RuntimeActionsPanel.Visible) 'Stopped state did not preserve Start and hide runtime actions.'
        foreach ($state in @('Online', 'Offline')) {
            $status.State = $state; $status.UpdateAvailable = $true; $status.CanUpdate = $true
            Apply-Status $status
            Assert-Compact ($script:UpdateButton.Visible -and $script:UpdateButton.IsDefault -and -not $script:StartButton.Visible -and -not $script:OpenButton.Visible) 'An update must remain the only primary action.'
            Assert-Compact ($script:StateTitle.Text -eq $text.UpdateTitle) 'Update state is missing its headline.'
        }
        $status.UpdateAvailable = $false; $status.CanUpdate = $false; $status.State = 'Online'; $status.DataAvailable = $false
        Apply-Status $status
        Assert-Compact ($script:StateTitle.Text -eq $text.NetworkTitle -and $script:DataDot.Fill -eq $script:launcherPalette.WarningBrush) 'Unavailable DATA must be visible without opening technical details.'
        foreach ($state in @('Unresponsive', 'PortConflict')) {
            $status.State = $state; $status.CanStart = $false; $status.CanOpen = $false; $status.CanRestart = ($state -eq 'Unresponsive'); $status.CanStop = ($state -eq 'Unresponsive')
            Apply-Status $status
            Assert-Compact (-not $script:OpenButton.Visible -and -not $script:StartButton.Visible -and $script:RestartButton.Visible -eq $status.CanRestart) 'Error state bypassed existing action visibility.'
        }
        $script:deploymentMessage = 'Missing published package'; $script:errorKind = ''
        Apply-Status $status
        Assert-Compact ($script:ErrorBanner.Visible -and $script:ErrorText.Text -eq $script:deploymentMessage) 'Deployment errors must stay visible outside the expander.'
        Show-Error 'Failed action' -Kind Action
        Apply-Status $status
        Assert-Compact ($script:ErrorText.Text -eq 'Failed action' -and $script:ErrorText.Foreground -eq $script:launcherPalette.DangerBrush) 'Status polling replaced the action error or used an unreadable theme color.'
    }
}
$installer = [IO.File]::ReadAllText((Join-Path $repo 'deploy/bootstrap/Install SAPHIR Shortcut.vbs'))
Assert-Compact ($installer -match 'CopyLauncherFile sourceLogoPath, localBundleLogoPath' -and $installer -match 'Not fso.FileExists\(localBundleLogoPath\) Or _') 'The automatic installer must copy and verify the immutable local logo.'
Write-Host 'Compact launcher passed: light/dark, FR/EN, checking/online/stopped/update/network/conflict/unresponsive states, action gating, local logo, expandable paths, long versions and persistent errors.'
