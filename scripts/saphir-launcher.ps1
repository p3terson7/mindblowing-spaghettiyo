param(
    [string]$DistributionRoot = "",
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or newer is required."
}

$runningOnWindows = $PSVersionTable.PSEdition -eq "Desktop" -or
    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if (-not $runningOnWindows) {
    throw "The SAPHIR graphical launcher is available on Windows only."
}
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    throw "The SAPHIR graphical launcher must run in STA mode."
}

$scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$launcherRoot = Split-Path -Path $scriptDirectory -Parent
$controllerPath = Join-Path -Path $scriptDirectory -ChildPath "lib/LauncherControl.ps1"
if (-not (Test-Path -LiteralPath $controllerPath -PathType Leaf)) {
    throw "The SAPHIR launcher controller is missing."
}

if ([string]::IsNullOrWhiteSpace($DistributionRoot)) {
    $DistributionRoot = $launcherRoot
}
elseif (-not [System.IO.Path]::IsPathRooted($DistributionRoot)) {
    throw "DistributionRoot must be an absolute path."
}
$DistributionRoot = [System.IO.Path]::GetFullPath($DistributionRoot)

Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Add-Type -AssemblyName System.Xaml -ErrorAction Stop

$mutex = New-Object System.Threading.Mutex($false, "Local\SAPHIR.GraphicalLauncher")
$ownsMutex = $false
try {
    try {
        $ownsMutex = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
    if (-not $ownsMutex) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.Popup(
                "Le lanceur SAPHIR est déjà ouvert.`nThe SAPHIR launcher is already open.",
                4,
                "SAPHIR",
                64
            )
        }
        catch {
        }
        return
    }

    $isFrench = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq "fr"
    $text = if ($isFrench) {
        @{
            WindowTitle       = "Lanceur SAPHIR"
            Subtitle          = "Gestion de l’application locale"
            Checking          = "Vérification en cours…"
            AppLabel          = "Application"
            DataLabel         = "Données partagées"
            ReleaseLabel      = "Version installée"
            Start             = "_Démarrer SAPHIR"
            Open              = "_Ouvrir SAPHIR"
            Restart           = "_Redémarrer"
            Stop              = "A_rrêter"
            Refresh           = "A_ctualiser"
            Logs              = "Ouvrir les _journaux"
            Online            = "En ligne"
            OnlineDetail      = "SAPHIR répond normalement et peut être ouvert."
            Offline           = "Hors ligne"
            OfflineDetail     = "SAPHIR est arrêté sur cet ordinateur."
            Unresponsive      = "Ne répond pas"
            UnresponsiveDetail = "Une instance SAPHIR est active, mais elle ne répond pas."
            Conflict          = "Port occupé"
            ConflictDetail    = "Un autre programme utilise le port local de SAPHIR. Il ne sera pas arrêté."
            Available         = "Accessible"
            Unavailable       = "Indisponible"
            NotConfigured     = "Non configuré"
            NotInstalled      = "Pas encore installée"
            Development       = "Développement"
            Starting          = "Démarrage de SAPHIR…"
            Restarting        = "Redémarrage de SAPHIR…"
            Stopping          = "Arrêt de SAPHIR…"
            StatusError       = "Impossible de vérifier l’état de SAPHIR."
            ActionError       = "L’opération n’a pas pu être terminée."
            OpenError         = "Le navigateur n’a pas pu être ouvert."
            LogsError         = "Le dossier des journaux n’a pas pu être ouvert."
            NeedsNetwork      = "Connectez-vous au réseau interne pour installer SAPHIR."
        }
    }
    else {
        @{
            WindowTitle       = "SAPHIR Launcher"
            Subtitle          = "Local application control"
            Checking          = "Checking status…"
            AppLabel          = "Application"
            DataLabel         = "Shared data"
            ReleaseLabel      = "Installed version"
            Start             = "_Start SAPHIR"
            Open              = "_Open SAPHIR"
            Restart           = "_Restart"
            Stop              = "S_top"
            Refresh           = "_Refresh"
            Logs              = "Open _logs"
            Online            = "Online"
            OnlineDetail      = "SAPHIR is responding normally and is ready to open."
            Offline           = "Offline"
            OfflineDetail     = "SAPHIR is stopped on this computer."
            Unresponsive      = "Not responding"
            UnresponsiveDetail = "A SAPHIR instance is active, but it is not responding."
            Conflict          = "Port conflict"
            ConflictDetail    = "Another program is using SAPHIR's local port. It will not be stopped."
            Available         = "Reachable"
            Unavailable       = "Unavailable"
            NotConfigured     = "Not configured"
            NotInstalled      = "Not installed yet"
            Development       = "Development"
            Starting          = "Starting SAPHIR…"
            Restarting        = "Restarting SAPHIR…"
            Stopping          = "Stopping SAPHIR…"
            StatusError       = "SAPHIR's status could not be checked."
            ActionError       = "The operation could not be completed."
            OpenError         = "The browser could not be opened."
            LogsError         = "The logs folder could not be opened."
            NeedsNetwork      = "Connect to the internal network to install SAPHIR."
        }
    }

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="LauncherWindow"
        Width="540"
        Height="570"
        MinWidth="540"
        MinHeight="570"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen"
        Background="#F5F5F7"
        FontFamily="Segoe UI"
        FontSize="14"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
    <Window.Resources>
        <Style x:Key="BaseButtonStyle" TargetType="{x:Type Button}">
            <Setter Property="MinHeight" Value="42"/>
            <Setter Property="Padding" Value="18,9"/>
            <Setter Property="Margin" Value="0,0,10,0"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="ButtonBorder"
                                CornerRadius="10"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                              RecognizesAccessKey="True"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.72"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.42"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="PrimaryButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource BaseButtonStyle}">
            <Setter Property="Background" Value="#0071E3"/>
            <Setter Property="BorderBrush" Value="#0071E3"/>
            <Setter Property="Foreground" Value="White"/>
        </Style>
        <Style x:Key="SecondaryButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource BaseButtonStyle}">
            <Setter Property="Background" Value="#F2F2F7"/>
            <Setter Property="BorderBrush" Value="#D8D8DE"/>
            <Setter Property="Foreground" Value="#1D1D1F"/>
        </Style>
        <Style x:Key="DangerButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource BaseButtonStyle}">
            <Setter Property="Background" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF3B30"/>
            <Setter Property="Foreground" Value="#D70015"/>
        </Style>
    </Window.Resources>
    <Grid Margin="28">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="18"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="16"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="SAPHIR" FontSize="28" FontWeight="SemiBold" Foreground="#1D1D1F"/>
                <TextBlock x:Name="SubtitleText" Margin="0,4,0,0" FontSize="14" Foreground="#6E6E73"/>
            </StackPanel>
            <Border Grid.Column="1" x:Name="StatusBadge" CornerRadius="14" Padding="12,6"
                    Background="#EFEFF4" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="StatusDot" Width="9" Height="9" Fill="#8E8E93"
                             Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="StatusBadgeText" FontWeight="SemiBold" Foreground="#3A3A3C"/>
                </StackPanel>
            </Border>
        </Grid>

        <Border Grid.Row="2" x:Name="MainCard" Background="White" BorderBrush="#DDDDE3"
                BorderThickness="1" CornerRadius="20" Padding="24">
            <Border.Effect>
                <DropShadowEffect BlurRadius="22" ShadowDepth="3" Opacity="0.08" Color="#000000"/>
            </Border.Effect>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="18"/>
                    <RowDefinition Height="1"/>
                    <RowDefinition Height="18"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="14"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="14"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="20"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" x:Name="StateTitle" FontSize="23" FontWeight="SemiBold"
                           Foreground="#1D1D1F"/>
                <TextBlock Grid.Row="1" x:Name="StateDetail" Margin="0,7,0,0" Foreground="#6E6E73"
                           TextWrapping="Wrap" MinHeight="40"/>
                <Border Grid.Row="3" Background="#E5E5EA"/>

                <Grid Grid.Row="5">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="155"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="ApplicationLabel" Foreground="#6E6E73"/>
                    <TextBlock Grid.Column="1" x:Name="ApplicationValue" FontWeight="SemiBold"
                               Foreground="#1D1D1F" TextAlignment="Right"/>
                </Grid>
                <Grid Grid.Row="7">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="155"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="DataLabel" Foreground="#6E6E73"/>
                    <StackPanel Grid.Column="1">
                        <TextBlock x:Name="DataValue" FontWeight="SemiBold" Foreground="#1D1D1F"
                                   TextAlignment="Right"/>
                        <TextBlock x:Name="DataPathText" Margin="0,3,0,0" FontSize="11"
                                   Foreground="#8E8E93" TextAlignment="Right"
                                   TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                </Grid>
                <Grid Grid.Row="9">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="155"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="ReleaseLabel" Foreground="#6E6E73"/>
                    <TextBlock Grid.Column="1" x:Name="ReleaseValue" FontWeight="SemiBold"
                               Foreground="#1D1D1F" TextAlignment="Right"
                               TextTrimming="CharacterEllipsis"/>
                </Grid>

                <ProgressBar Grid.Row="11" x:Name="BusyProgress" Height="4"
                             IsIndeterminate="True" Visibility="Collapsed"
                             Foreground="#0071E3" Background="#E5E5EA"/>
                <TextBlock Grid.Row="12" x:Name="BusyText" Margin="0,8,0,0"
                           Foreground="#6E6E73" Visibility="Collapsed"/>
                <Border Grid.Row="13" x:Name="ErrorBanner" Margin="0,12,0,0"
                        Padding="12,9" CornerRadius="9" Background="#FFF1F0"
                        BorderBrush="#FFD0CC" BorderThickness="1" Visibility="Collapsed">
                    <TextBlock x:Name="ErrorText" Foreground="#A51C14" TextWrapping="Wrap"/>
                </Border>
            </Grid>
        </Border>

        <Grid Grid.Row="4">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="12"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal">
                <Button x:Name="StartButton" Style="{StaticResource PrimaryButtonStyle}"/>
                <Button x:Name="OpenButton" Style="{StaticResource PrimaryButtonStyle}" IsDefault="True"/>
                <Button x:Name="RestartButton" Style="{StaticResource SecondaryButtonStyle}"/>
                <Button x:Name="StopButton" Style="{StaticResource DangerButtonStyle}" Margin="0"/>
            </StackPanel>
            <Grid Grid.Row="2">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="LogsButton" Style="{StaticResource SecondaryButtonStyle}"/>
                <Button Grid.Column="1" x:Name="RefreshButton" Style="{StaticResource SecondaryButtonStyle}" Margin="0"/>
            </Grid>
        </Grid>
    </Grid>
</Window>
'@

    $xmlReader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    $xmlReader.Close()

    $names = @(
        "SubtitleText", "StatusBadge", "StatusDot", "StatusBadgeText", "MainCard",
        "StateTitle", "StateDetail", "ApplicationLabel", "ApplicationValue",
        "DataLabel", "DataValue", "DataPathText", "ReleaseLabel", "ReleaseValue",
        "BusyProgress", "BusyText", "ErrorBanner", "ErrorText", "StartButton",
        "OpenButton", "RestartButton", "StopButton", "LogsButton", "RefreshButton"
    )
    foreach ($name in $names) {
        Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
    }

    $window.Title = $text.WindowTitle
    $script:SubtitleText.Text = $text.Subtitle
    $script:ApplicationLabel.Text = $text.AppLabel
    $script:DataLabel.Text = $text.DataLabel
    $script:ReleaseLabel.Text = $text.ReleaseLabel
    $script:StartButton.Content = $text.Start
    $script:OpenButton.Content = $text.Open
    $script:RestartButton.Content = $text.Restart
    $script:StopButton.Content = $text.Stop
    $script:LogsButton.Content = $text.Logs
    $script:RefreshButton.Content = $text.Refresh

    $iconCandidates = @(
        (Join-Path -Path $launcherRoot -ChildPath "SAPHIR.ico"),
        (Join-Path -Path (Split-Path -Path $launcherRoot -Parent) -ChildPath "assets/SAPHIR.ico")
    )
    foreach ($iconPath in $iconCandidates) {
        if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
            try {
                $iconUri = New-Object System.Uri($iconPath, [System.UriKind]::Absolute)
                $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($iconUri)
            }
            catch {
            }
            break
        }
    }

    if ([System.Windows.SystemParameters]::HighContrast) {
        $window.Background = [System.Windows.SystemColors]::WindowBrush
        $script:MainCard.Background = [System.Windows.SystemColors]::ControlBrush
        $script:MainCard.BorderBrush = [System.Windows.SystemColors]::ActiveBorderBrush
    }

    if ($ValidateOnly) {
        Write-Host "SAPHIR launcher validation passed."
        return
    }

    function New-Brush {
        param([Parameter(Mandatory = $true)][string]$Color)
        return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    }

    function Set-Visible {
        param(
            [Parameter(Mandatory = $true)]$Element,
            [Parameter(Mandatory = $true)][bool]$Visible
        )
        $Element.Visibility = if ($Visible) {
            [System.Windows.Visibility]::Visible
        }
        else {
            [System.Windows.Visibility]::Collapsed
        }
    }

    $script:lastStatus = $null
    $script:actionBusy = $false
    $script:closing = $false
    $script:statusWorker = $null
    $script:statusHandle = $null
    $script:statusShowsProgress = $false
    $script:discardStatusResult = $false
    $script:actionWorker = $null
    $script:actionHandle = $null
    $script:actionName = ""
    $script:errorKind = ""

    function Hide-Error {
        Set-Visible -Element $script:ErrorBanner -Visible $false
        $script:ErrorText.Text = ""
        $script:errorKind = ""
    }

    function Show-Error {
        param(
            [Parameter(Mandatory = $true)][string]$Message,
            [ValidateSet("Status", "Action", "User")][string]$Kind = "User"
        )
        if ($Message.Length -gt 320) {
            $Message = $Message.Substring(0, 317) + "…"
        }
        $script:ErrorText.Text = $Message
        $script:errorKind = $Kind
        Set-Visible -Element $script:ErrorBanner -Visible $true
    }

    function Set-BusyState {
        param(
            [Parameter(Mandatory = $true)][bool]$Busy,
            [string]$Message = ""
        )

        $script:actionBusy = $Busy
        Set-Visible -Element $script:BusyProgress -Visible $Busy
        Set-Visible -Element $script:BusyText -Visible $Busy
        $script:BusyText.Text = $Message
        foreach ($button in @(
            $script:StartButton,
            $script:OpenButton,
            $script:RestartButton,
            $script:StopButton,
            $script:RefreshButton
        )) {
            $button.IsEnabled = -not $Busy
        }
        if (-not $Busy -and $null -ne $script:lastStatus) {
            $script:StartButton.IsEnabled = [bool]$script:lastStatus.CanStart
            $script:OpenButton.IsEnabled = [bool]$script:lastStatus.CanOpen
            $script:RestartButton.IsEnabled = [bool]$script:lastStatus.CanRestart
            $script:StopButton.IsEnabled = [bool]$script:lastStatus.CanStop
        }
    }

    function Set-CheckingPresentation {
        $script:StatusBadge.Background = New-Brush -Color "#EFEFF4"
        $script:StatusDot.Fill = New-Brush -Color "#8E8E93"
        $script:StatusBadgeText.Foreground = New-Brush -Color "#3A3A3C"
        $script:StatusBadgeText.Text = $text.Checking
        $script:StateTitle.Text = $text.Checking
        $script:StateDetail.Text = ""
        $script:ApplicationValue.Text = "—"
        $script:DataValue.Text = "—"
        $script:DataPathText.Text = ""
        $script:ReleaseValue.Text = "—"
        foreach ($button in @($script:StartButton, $script:OpenButton, $script:RestartButton, $script:StopButton)) {
            Set-Visible -Element $button -Visible $false
        }
    }

    function Apply-Status {
        param([Parameter(Mandatory = $true)]$Status)

        $script:lastStatus = $Status
        $state = [string]$Status.State
        $statusTitle = $text.Offline
        $detail = $text.OfflineDetail
        $dotColor = "#8E8E93"
        $badgeBackground = "#EFEFF4"
        $badgeForeground = "#3A3A3C"

        switch ($state) {
            "Online" {
                $statusTitle = $text.Online
                $detail = $text.OnlineDetail
                $dotColor = "#34C759"
                $badgeBackground = "#EAF8EF"
                $badgeForeground = "#176B35"
            }
            "Unresponsive" {
                $statusTitle = $text.Unresponsive
                $detail = $text.UnresponsiveDetail
                $dotColor = "#FF9F0A"
                $badgeBackground = "#FFF6E5"
                $badgeForeground = "#8A4B00"
            }
            "PortConflict" {
                $statusTitle = $text.Conflict
                $detail = $text.ConflictDetail
                $dotColor = "#FF3B30"
                $badgeBackground = "#FFF0EF"
                $badgeForeground = "#A51C14"
            }
            default {
                if ([string]::IsNullOrWhiteSpace([string]$Status.ReleaseId) -and
                    -not [bool]$Status.DistributionAvailable) {
                    $detail = $text.NeedsNetwork
                }
            }
        }

        $script:StatusBadge.Background = New-Brush -Color $badgeBackground
        $script:StatusDot.Fill = New-Brush -Color $dotColor
        $script:StatusBadgeText.Foreground = New-Brush -Color $badgeForeground
        $script:StatusBadgeText.Text = $statusTitle
        $script:StateTitle.Text = $statusTitle
        $script:StateDetail.Text = $detail
        $script:ApplicationValue.Text = $statusTitle

        $dataPath = [string]$Status.DataFolderPath
        if ([string]::IsNullOrWhiteSpace($dataPath)) {
            $script:DataValue.Text = $text.NotConfigured
            $script:DataValue.Foreground = New-Brush -Color "#8E8E93"
            $script:DataPathText.Text = ""
            $script:DataPathText.ToolTip = $null
        }
        elseif ([bool]$Status.DataAvailable) {
            $script:DataValue.Text = $text.Available
            $script:DataValue.Foreground = New-Brush -Color "#248A3D"
            $script:DataPathText.Text = $dataPath
            $script:DataPathText.ToolTip = $dataPath
        }
        else {
            $script:DataValue.Text = $text.Unavailable
            $script:DataValue.Foreground = New-Brush -Color "#B25000"
            $script:DataPathText.Text = $dataPath
            $script:DataPathText.ToolTip = $dataPath
        }

        $releaseId = [string]$Status.ReleaseId
        if ([string]::IsNullOrWhiteSpace($releaseId)) {
            $releaseId = $text.NotInstalled
        }
        elseif ($releaseId -eq "development") {
            $releaseId = $text.Development
        }
        $script:ReleaseValue.Text = $releaseId
        $script:ReleaseValue.ToolTip = $releaseId

        Set-Visible -Element $script:StartButton -Visible ($state -eq "Offline")
        Set-Visible -Element $script:OpenButton -Visible ($state -eq "Online")
        Set-Visible -Element $script:RestartButton -Visible ($state -eq "Online" -or $state -eq "Unresponsive")
        Set-Visible -Element $script:StopButton -Visible ($state -eq "Online" -or $state -eq "Unresponsive")

        if (-not $script:actionBusy) {
            $script:StartButton.IsEnabled = [bool]$Status.CanStart
            $script:OpenButton.IsEnabled = [bool]$Status.CanOpen
            $script:RestartButton.IsEnabled = [bool]$Status.CanRestart
            $script:StopButton.IsEnabled = [bool]$Status.CanStop
            $script:RefreshButton.IsEnabled = $true
        }
    }

    $workerScript = @'
param($ControllerPath, $DistributionRoot, $Operation, $Action)
$ErrorActionPreference = "Stop"
. $ControllerPath
if ($Operation -eq "Status") {
    Get-SaphirLauncherStatus -DistributionRoot $DistributionRoot
    return
}
Invoke-SaphirLauncherAction -Action $Action -DistributionRoot $DistributionRoot
'@

    $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 2)
    $runspacePool.Open()

    function New-LauncherWorker {
        param(
            [Parameter(Mandatory = $true)][string]$Operation,
            [string]$Action = ""
        )

        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.RunspacePool = $runspacePool
        [void]$worker.AddScript($workerScript)
        [void]$worker.AddArgument($controllerPath)
        [void]$worker.AddArgument($DistributionRoot)
        [void]$worker.AddArgument($Operation)
        [void]$worker.AddArgument($Action)
        return $worker
    }

    function Start-StatusRefresh {
        param([switch]$ShowProgress)

        if ($script:closing -or $null -ne $script:statusWorker -or $null -ne $script:actionWorker) {
            return
        }

        $script:statusShowsProgress = [bool]$ShowProgress
        if ($script:statusShowsProgress) {
            Set-BusyState -Busy $true -Message $text.Checking
        }
        $script:statusWorker = New-LauncherWorker -Operation "Status"
        $script:discardStatusResult = $false
        $script:statusHandle = $script:statusWorker.BeginInvoke()
    }

    function Start-LauncherAction {
        param([Parameter(Mandatory = $true)][ValidateSet("Start", "Restart", "Stop")][string]$Action)

        if ($script:closing -or $null -ne $script:actionWorker) {
            return
        }

        Hide-Error
        $busyMessage = switch ($Action) {
            "Start" { $text.Starting }
            "Restart" { $text.Restarting }
            default { $text.Stopping }
        }
        Set-BusyState -Busy $true -Message $busyMessage
        if ($null -ne $script:statusWorker) {
            # A snapshot that started before this mutation may become stale.
            $script:discardStatusResult = $true
        }
        $script:actionName = $Action
        $script:actionWorker = New-LauncherWorker -Operation "Action" -Action $Action
        $script:actionHandle = $script:actionWorker.BeginInvoke()
    }

    function Get-WorkerStatusResult {
        param(
            [Parameter(Mandatory = $true)]$Worker,
            [Parameter(Mandatory = $true)]$Handle
        )

        $output = @($Worker.EndInvoke($Handle))
        if ($Worker.Streams.Error.Count -gt 0) {
            throw [string]$Worker.Streams.Error[$Worker.Streams.Error.Count - 1]
        }
        $status = @($output | Where-Object {
            $null -ne $_ -and $_.PSObject.Properties.Name -contains "State"
        } | Select-Object -Last 1)
        if ($status.Count -eq 0) {
            throw "The SAPHIR controller did not return a status."
        }
        return $status[0]
    }

    $workerTimer = New-Object System.Windows.Threading.DispatcherTimer
    $workerTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $workerTimer.Add_Tick({
        if ($null -ne $script:statusWorker -and $script:statusHandle.IsCompleted) {
            $completedWorker = $script:statusWorker
            $completedHandle = $script:statusHandle
            $completedStatusShowedProgress = $script:statusShowsProgress
            $script:statusWorker = $null
            $script:statusHandle = $null
            $script:statusShowsProgress = $false
            try {
                $status = Get-WorkerStatusResult -Worker $completedWorker -Handle $completedHandle
                if (-not $script:discardStatusResult) {
                    Apply-Status -Status $status
                    if (-not $script:actionBusy -and $script:errorKind -eq "Status") {
                        Hide-Error
                    }
                }
            }
            catch {
                if ($null -eq $script:lastStatus) {
                    $script:StatusBadgeText.Text = $text.Unavailable
                    $script:StateTitle.Text = $text.StatusError
                }
                if ($script:errorKind -ne "Action" -and $script:errorKind -ne "User") {
                    Show-Error -Message $text.StatusError -Kind "Status"
                }
            }
            finally {
                $script:discardStatusResult = $false
                $completedWorker.Dispose()
                if ($completedStatusShowedProgress) {
                    Set-BusyState -Busy $false
                }
            }
        }

        if ($null -ne $script:actionWorker -and $script:actionHandle.IsCompleted) {
            $completedWorker = $script:actionWorker
            $completedHandle = $script:actionHandle
            $script:actionWorker = $null
            $script:actionHandle = $null
            try {
                $status = Get-WorkerStatusResult -Worker $completedWorker -Handle $completedHandle
                Apply-Status -Status $status
                Hide-Error
            }
            catch {
                $message = [string]$_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $message = $text.ActionError
                }
                Show-Error -Message ("{0} {1}" -f $text.ActionError, $message) -Kind "Action"
            }
            finally {
                $completedWorker.Dispose()
                $script:actionName = ""
                Set-BusyState -Busy $false
                Start-StatusRefresh
            }
        }
    })
    $workerTimer.Start()

    $refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
    $refreshTimer.Interval = [TimeSpan]::FromSeconds(4)
    $refreshTimer.Add_Tick({
        Start-StatusRefresh
    })
    $refreshTimer.Start()

    $script:StartButton.Add_Click({ Start-LauncherAction -Action "Start" })
    $script:RestartButton.Add_Click({ Start-LauncherAction -Action "Restart" })
    $script:StopButton.Add_Click({ Start-LauncherAction -Action "Stop" })
    $script:RefreshButton.Add_Click({
        Hide-Error
        Start-StatusRefresh -ShowProgress
    })
    $script:OpenButton.Add_Click({
        if ($script:actionBusy -or $null -eq $script:lastStatus -or -not [bool]$script:lastStatus.CanOpen) {
            return
        }
        try {
            Start-Process -FilePath ([string]$script:lastStatus.FrontendUrl) | Out-Null
        }
        catch {
            Show-Error -Message $text.OpenError -Kind "User"
        }
    })
    $script:LogsButton.Add_Click({
        try {
            $logsPath = if ($null -ne $script:lastStatus -and
                -not [string]::IsNullOrWhiteSpace([string]$script:lastStatus.LogsPath)) {
                [string]$script:lastStatus.LogsPath
            }
            else {
                $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
                Join-Path -Path $localAppData -ChildPath "SAPHIR/runtime/logs"
            }
            if (-not (Test-Path -LiteralPath $logsPath -PathType Container)) {
                New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
            }
            Start-Process -FilePath $logsPath | Out-Null
        }
        catch {
            Show-Error -Message $text.LogsError -Kind "User"
        }
    })

    Set-CheckingPresentation
    $window.Add_ContentRendered({
        Start-StatusRefresh -ShowProgress
    })
    $window.Add_Closing({
        $script:closing = $true
        $workerTimer.Stop()
        $refreshTimer.Stop()
    })
    $window.Add_Closed({
        foreach ($worker in @($script:statusWorker, $script:actionWorker)) {
            if ($null -ne $worker) {
                try { $worker.BeginStop($null, $null) | Out-Null } catch { }
            }
        }
        try { [void]$runspacePool.BeginClose($null, $null) } catch { }
    })

    [void]$window.ShowDialog()
}
finally {
    if ($ownsMutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}
