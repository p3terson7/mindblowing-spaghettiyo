param(
    [string]$DistributionRoot = "",
    [switch]$ValidateOnly,
    [ValidateSet("Dark", "Light", "System")][string]$Theme = "Dark"
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
            Subtitle          = "Gestion des heures supplémentaires"
            Connections       = "Connexions"
            TechnicalDetails  = "Détails techniques"
            VersionHeading    = "Version de l’application"
            LastChecked       = "Dernière vérification · {0}"
            ReadyTitle        = "Votre espace est prêt."
            StoppedTitle      = "Prêt à démarrer ?"
            UpdateTitle       = "Une mise à jour est prête."
            NetworkTitle      = "Connexion réseau à vérifier."
            NetworkDetail     = "Le dossier partagé ne répond pas. Vérifiez le réseau ou le VPN."
            Checking          = "Vérification en cours…"
            AppLabel          = "Application"
            DataLabel         = "Données partagées"
            DistributionLabel = "Réseau de distribution"
            ReleaseLabel      = "Version installée"
            TargetReleaseLabel = "Version disponible"
            Start             = "_Démarrer SAPHIR"
            Open              = "_Ouvrir SAPHIR"
            Restart           = "_Redémarrer"
            UpdateAndStart    = "_Mettre à jour et démarrer"
            UpdateAndRestart  = "_Mettre à jour et redémarrer"
            Repair            = "_Réparer"
            Stop              = "A_rrêter"
            Refresh           = "A_ctualiser"
            Logs              = "_Journaux"
            Online            = "En ligne"
            OnlineDetail      = "Ouvrez SAPHIR pour commencer."
            Offline           = "Hors ligne"
            OfflineDetail     = "SAPHIR est arrêté sur cet ordinateur."
            Unresponsive      = "Ne répond pas"
            UnresponsiveDetail = "Une instance SAPHIR est active, mais elle ne répond pas."
            Conflict          = "Port occupé"
            ConflictDetail    = "Un autre programme utilise le port local de SAPHIR. Il ne sera pas arrêté."
            Available         = "Accessible"
            Unavailable       = "Indisponible"
            NeedsAttention    = "À vérifier"
            NotConfigured     = "Non configuré"
            NotInstalled      = "Pas encore installée"
            Development       = "Développement"
            CurrentRelease    = "À jour"
            UpdateAvailable   = "mise à jour"
            PreviousFailure   = "échec précédent"
            UpdateOnStart     = "La version {0} est disponible. Cliquez sur Mettre à jour et démarrer."
            UpdateOnRestart   = "La version {0} est disponible. Cliquez sur Mettre à jour et redémarrer."
            Starting          = "Démarrage de SAPHIR…"
            Restarting        = "Redémarrage de SAPHIR…"
            Updating          = "Installation de la mise à jour…"
            Repairing         = "Vérification et réparation de SAPHIR…"
            Stopping          = "Arrêt de SAPHIR…"
            StatusError       = "Impossible de vérifier l’état de SAPHIR."
            ActionError       = "L’opération n’a pas pu être terminée."
            OpenError         = "Le navigateur n’a pas pu être ouvert."
            LogsError         = "Le dossier des journaux n’a pas pu être ouvert."
            NeedsNetwork      = "Connectez-vous au réseau interne pour installer SAPHIR."
            DistributionUnavailable = "Le dossier de distribution est inaccessible : {0}. Connectez-vous au réseau interne ou corrigez distribution-root.txt."
            ManifestMissing   = "Aucune version publiée n’est détectable : {0} est absent. Le ZIP seul ne suffit pas; republiez l’application pour mettre current.json à jour."
            ManifestUnavailable = "Le pointeur de version ne peut pas être lu : {0}. Vérifiez l’accès au réseau, puis republiez au besoin."
            ManifestUnreadable = "Le fichier current.json est illisible ou incomplet. Republiez l’application au lieu de modifier ce fichier manuellement."
            ManifestUnsupported = "Le format de current.json n’est pas pris en charge. Republiez avec le script de packaging actuel."
            ReleaseIdInvalid  = "Le ReleaseId de current.json est invalide. Republiez avec un nouvel identifiant compatible Windows."
            ChecksumInvalid   = "La somme de contrôle de la version {0} est invalide. Republiez la version."
            PackagePathInvalid = "Le chemin du ZIP de la version {0} est invalide. Republiez l’application."
            DataPathInvalid   = "Le chemin DATA de la version {0} est invalide. Republiez avec le bon DataFolderPath."
            PackageUnavailable = "current.json annonce la version {0}, mais son ZIP est introuvable : {1}. Republiez cette version ou restaurez le ZIP correspondant."
            TargetDataUnavailable = "La version {0} pointe vers un dossier DATA inaccessible : {1}. Rétablissez l’accès réseau ou republiez avec le bon chemin."
            TargetPreviouslyFailed = "La version {0} a échoué lors d’une tentative précédente. Cliquez sur Réparer SAPHIR pour la retélécharger et la vérifier automatiquement."
        }
    }
    else {
        @{
            WindowTitle       = "SAPHIR Launcher"
            Subtitle          = "Overtime management"
            Connections       = "Connections"
            TechnicalDetails  = "Technical details"
            VersionHeading    = "Application version"
            LastChecked       = "Last checked · {0}"
            ReadyTitle        = "Your workspace is ready."
            StoppedTitle      = "Ready to start?"
            UpdateTitle       = "An update is ready."
            NetworkTitle      = "Check your network connection."
            NetworkDetail     = "The shared folder is not responding. Check your network or VPN connection."
            Checking          = "Checking status…"
            AppLabel          = "Application"
            DataLabel         = "Shared data"
            DistributionLabel = "Distribution network"
            ReleaseLabel      = "Installed version"
            TargetReleaseLabel = "Available version"
            Start             = "_Start SAPHIR"
            Open              = "_Open SAPHIR"
            Restart           = "_Restart"
            UpdateAndStart    = "_Update and start"
            UpdateAndRestart  = "_Update and restart"
            Repair            = "_Repair"
            Stop              = "S_top"
            Refresh           = "_Refresh"
            Logs              = "_Logs"
            Online            = "Online"
            OnlineDetail      = "Open SAPHIR to get started."
            Offline           = "Offline"
            OfflineDetail     = "SAPHIR is stopped on this computer."
            Unresponsive      = "Not responding"
            UnresponsiveDetail = "A SAPHIR instance is active, but it is not responding."
            Conflict          = "Port conflict"
            ConflictDetail    = "Another program is using SAPHIR's local port. It will not be stopped."
            Available         = "Reachable"
            Unavailable       = "Unavailable"
            NeedsAttention    = "Needs attention"
            NotConfigured     = "Not configured"
            NotInstalled      = "Not installed yet"
            Development       = "Development"
            CurrentRelease    = "Up to date"
            UpdateAvailable   = "update available"
            PreviousFailure   = "previous failure"
            UpdateOnStart     = "Release {0} is available. Select Update and start."
            UpdateOnRestart   = "Release {0} is available. Select Update and restart."
            Starting          = "Starting SAPHIR…"
            Restarting        = "Restarting SAPHIR…"
            Updating          = "Installing the update…"
            Repairing         = "Checking and repairing SAPHIR…"
            Stopping          = "Stopping SAPHIR…"
            StatusError       = "SAPHIR's status could not be checked."
            ActionError       = "The operation could not be completed."
            OpenError         = "The browser could not be opened."
            LogsError         = "The logs folder could not be opened."
            NeedsNetwork      = "Connect to the internal network to install SAPHIR."
            DistributionUnavailable = "The distribution folder is unavailable: {0}. Connect to the internal network or correct distribution-root.txt."
            ManifestMissing   = "No published release can be detected because {0} is missing. The ZIP alone is not enough; publish the application so current.json is updated."
            ManifestUnavailable = "The release pointer cannot be read: {0}. Check network access, then republish if needed."
            ManifestUnreadable = "current.json is unreadable or incomplete. Republish the application instead of editing this file manually."
            ManifestUnsupported = "The current.json format is unsupported. Republish with the current packaging script."
            ReleaseIdInvalid  = "The ReleaseId in current.json is invalid. Republish with a new Windows-safe identifier."
            ChecksumInvalid   = "The checksum for release {0} is invalid. Republish the release."
            PackagePathInvalid = "The ZIP path for release {0} is invalid. Republish the application."
            DataPathInvalid   = "The DATA path for release {0} is invalid. Republish with the correct DataFolderPath."
            PackageUnavailable = "current.json announces release {0}, but its ZIP is missing: {1}. Republish this release or restore the matching ZIP."
            TargetDataUnavailable = "Release {0} points to an unavailable DATA folder: {1}. Restore network access or republish with the correct path."
            TargetPreviouslyFailed = "Release {0} failed during an earlier attempt. Click Repair SAPHIR to download and verify it again automatically."
        }
    }

    function Get-LauncherThemePalette {
        param([ValidateSet("Dark", "Light")][string]$Appearance = "Dark")
        $palette = @{
            ShellBrush = "#1C1D22"; SurfaceBrush = "#25262C"; SoftBrush = "#2C2D34"
            TextBrush = "#ECECF0"; MutedBrush = "#A2A5B0"; LineBrush = "#3A3B44"
            AccentBrush = "#65A9FF"; AccentTextBrush = "#10233B"; AccentHoverBrush = "#81B9FF"
            SuccessBrush = "#64D9B1"; SuccessSoftBrush = "#243D37"
            WarningBrush = "#EDC471"; WarningSoftBrush = "#403727"
            DangerBrush = "#FA8991"; DangerSoftBrush = "#432C31"
        }
        if ($Appearance -eq "Light") {
            $palette = @{
                ShellBrush = "#F5F6F8"; SurfaceBrush = "#FFFFFF"; SoftBrush = "#F0F2F5"
                TextBrush = "#202126"; MutedBrush = "#666A74"; LineBrush = "#DEDFE5"
                AccentBrush = "#0767CF"; AccentTextBrush = "#FFFFFF"; AccentHoverBrush = "#075BB7"
                SuccessBrush = "#16805A"; SuccessSoftBrush = "#E5F4EE"
                WarningBrush = "#985F06"; WarningSoftBrush = "#FFF3DC"
                DangerBrush = "#BA3D46"; DangerSoftBrush = "#FCEBED"
            }
        }
        return $palette
    }

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="LauncherWindow" Width="520" Height="750" MinWidth="460" MinHeight="540"
        ResizeMode="CanResizeWithGrip" WindowStartupLocation="CenterScreen"
        Background="{DynamicResource ShellBrush}" Foreground="{DynamicResource TextBrush}"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
    <Window.Resources>
        <SolidColorBrush x:Key="ShellBrush" Color="#1C1D22"/>
        <SolidColorBrush x:Key="SurfaceBrush" Color="#25262C"/>
        <SolidColorBrush x:Key="SoftBrush" Color="#2C2D34"/>
        <SolidColorBrush x:Key="TextBrush" Color="#ECECF0"/>
        <SolidColorBrush x:Key="MutedBrush" Color="#A2A5B0"/>
        <SolidColorBrush x:Key="LineBrush" Color="#3A3B44"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#65A9FF"/>
        <SolidColorBrush x:Key="AccentTextBrush" Color="#10233B"/>
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#81B9FF"/>
        <SolidColorBrush x:Key="SuccessBrush" Color="#64D9B1"/>
        <SolidColorBrush x:Key="SuccessSoftBrush" Color="#243D37"/>
        <SolidColorBrush x:Key="WarningBrush" Color="#EDC471"/>
        <SolidColorBrush x:Key="WarningSoftBrush" Color="#403727"/>
        <SolidColorBrush x:Key="DangerBrush" Color="#FA8991"/>
        <SolidColorBrush x:Key="DangerSoftBrush" Color="#432C31"/>
        <Style TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
        </Style>
        <Style x:Key="BaseButtonStyle" TargetType="{x:Type Button}">
            <Setter Property="MinHeight" Value="36"/>
            <Setter Property="Padding" Value="9,7"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
            <Setter Property="AutomationProperties.Name" Value="{Binding ToolTip, RelativeSource={RelativeSource Self}}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="ButtonBorder" CornerRadius="7"
                                Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                                <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="{TemplateBinding Tag}"
                                           Foreground="{TemplateBinding Foreground}" Margin="0,0,7,0" VerticalAlignment="Center"/>
                                <ContentPresenter RecognizesAccessKey="True" VerticalAlignment="Center"/>
                            </StackPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource SoftBrush}"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.75"/></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.42"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="UtilityButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource BaseButtonStyle}"/>
        <Style x:Key="PrimaryButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource BaseButtonStyle}">
            <Setter Property="MinHeight" Value="45"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="{DynamicResource AccentTextBrush}"/>
            <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="ButtonBorder" CornerRadius="9" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                                <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="16" Text="{TemplateBinding Tag}"
                                           Foreground="{TemplateBinding Foreground}" Margin="0,0,9,0" VerticalAlignment="Center"/>
                                <ContentPresenter RecognizesAccessKey="True" VerticalAlignment="Center"/>
                            </StackPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource AccentHoverBrush}"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.8"/></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{DynamicResource TextBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.42"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="IconButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource BaseButtonStyle}">
            <Setter Property="Width" Value="36"/>
            <Setter Property="Height" Value="36"/>
            <Setter Property="Padding" Value="8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="ButtonBorder" CornerRadius="7" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
                            <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="16" Text="{TemplateBinding Tag}"
                                       Foreground="{TemplateBinding Foreground}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="{DynamicResource SoftBrush}"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.75"/></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.42"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DangerIconButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource IconButtonStyle}">
            <Setter Property="Foreground" Value="{DynamicResource DangerBrush}"/>
        </Style>
        <Style x:Key="InfoTileStyle" TargetType="{x:Type Border}">
            <Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="11"/>
            <Setter Property="Padding" Value="15"/>
        </Style>
        <Style x:Key="DetailValueStyle" TargetType="{x:Type TextBlock}">
            <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="Margin" Value="0,3,0,10"/>
        </Style>
        <Style x:Key="DetailsExpanderStyle" TargetType="{x:Type Expander}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Expander}">
                        <StackPanel>
                            <ToggleButton x:Name="DetailsToggle" IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          Content="{TemplateBinding Header}" Foreground="{DynamicResource MutedBrush}"
                                          Background="Transparent" BorderBrush="Transparent" BorderThickness="1" Padding="1,8" Cursor="Hand">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                                        <Border x:Name="ToggleBorder" BorderThickness="1" BorderBrush="{TemplateBinding BorderBrush}" Padding="{TemplateBinding Padding}">
                                            <DockPanel>
                                                <TextBlock DockPanel.Dock="Right" x:Name="Chevron" FontFamily="Segoe MDL2 Assets" Text="&#xE70D;"
                                                           FontSize="11" Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center"/>
                                                <ContentPresenter RecognizesAccessKey="True" VerticalAlignment="Center"/>
                                            </DockPanel>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsChecked" Value="True"><Setter TargetName="Chevron" Property="Text" Value="&#xE70E;"/></Trigger>
                                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ToggleBorder" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <Border x:Name="DetailsBody" Visibility="Collapsed" Margin="0,6,0,0" Padding="13,12,13,2"
                                    Background="{DynamicResource SoftBrush}" CornerRadius="8">
                                <ContentPresenter/>
                            </Border>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsExpanded" Value="True"><Setter TargetName="DetailsBody" Property="Visibility" Value="Visible"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False">
        <StackPanel Margin="24,22,24,20">
            <Grid Margin="0,0,0,22">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Image x:Name="BrandLogo" Width="46" Height="46" Margin="0,0,12,0" Stretch="Uniform"
                       RenderOptions.BitmapScalingMode="HighQuality" AutomationProperties.Name="SAPHIR"/>
                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,10,0">
                    <TextBlock Text="SAPHIR" FontSize="21" FontWeight="SemiBold"/>
                    <TextBlock x:Name="SubtitleText" Margin="0,2,0,0" FontSize="12" Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap"/>
                </StackPanel>
                <Border Grid.Column="2" x:Name="StatusBadge" CornerRadius="14" Padding="9,5" VerticalAlignment="Center"
                        Background="{DynamicResource SoftBrush}" MaxWidth="150">
                    <StackPanel Orientation="Horizontal">
                        <Ellipse x:Name="StatusDot" Width="6" Height="6" Margin="0,0,6,0" Fill="{DynamicResource MutedBrush}" VerticalAlignment="Center"/>
                        <TextBlock x:Name="StatusBadgeText" FontSize="11" Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap" MaxWidth="116"/>
                    </StackPanel>
                </Border>
            </Grid>
            <StackPanel x:Name="MainCard">
                <Grid Margin="0,4,0,20">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border x:Name="StateIconBadge" Width="42" Height="42" CornerRadius="12" Background="{DynamicResource SoftBrush}"
                            Margin="0,0,13,0" VerticalAlignment="Top">
                        <TextBlock x:Name="StateIcon" FontFamily="Segoe MDL2 Assets" FontSize="20" Text="&#xE72C;"
                                   Foreground="{DynamicResource MutedBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Grid.Column="1">
                        <TextBlock x:Name="StateTitle" FontSize="21" FontWeight="SemiBold" TextWrapping="Wrap"/>
                        <TextBlock x:Name="StateDetail" Margin="0,5,0,0" Foreground="{DynamicResource MutedBrush}" FontSize="12" TextWrapping="Wrap"/>
                    </StackPanel>
                </Grid>
                <Grid>
                    <Button x:Name="StartButton" Style="{StaticResource PrimaryButtonStyle}" Tag="&#xE768;"/>
                    <Button x:Name="UpdateButton" Style="{StaticResource PrimaryButtonStyle}" Tag="&#xE895;"/>
                    <Button x:Name="OpenButton" Style="{StaticResource PrimaryButtonStyle}" Tag="&#xE8A7;"/>
                </Grid>
                <ProgressBar x:Name="BusyProgress" Margin="0,12,0,0" Height="3" IsIndeterminate="True" Visibility="Collapsed"
                             Foreground="{DynamicResource AccentBrush}" Background="{DynamicResource SoftBrush}"/>
                <TextBlock x:Name="BusyText" Margin="0,6,0,0" FontSize="12" Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap" Visibility="Collapsed"/>
                <Border x:Name="ErrorBanner" Margin="0,12,0,0" Padding="12,10" CornerRadius="8"
                        Background="{DynamicResource DangerSoftBrush}" BorderBrush="{DynamicResource DangerBrush}" BorderThickness="1" Visibility="Collapsed">
                    <TextBlock x:Name="ErrorText" FontSize="12" Foreground="{DynamicResource DangerBrush}" TextWrapping="Wrap"
                               AutomationProperties.LiveSetting="Polite"/>
                </Border>
            </StackPanel>
            <TextBlock x:Name="ConnectionsLabel" FontSize="12" Margin="0,21,0,9" Foreground="{DynamicResource MutedBrush}"/>
            <Border Style="{StaticResource InfoTileStyle}" Padding="0">
                <StackPanel>
                    <Grid Margin="14,12">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7F4;" FontSize="16" Foreground="{DynamicResource MutedBrush}" Margin="0,0,11,0" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="1" x:Name="ApplicationLabel" FontSize="12" Foreground="{DynamicResource MutedBrush}" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="2" x:Name="ApplicationValue" FontSize="12" VerticalAlignment="Center"/>
                        <Ellipse Grid.Column="3" x:Name="ApplicationDot" Width="6" Height="6" Margin="11,0,0,0" Fill="{DynamicResource MutedBrush}" VerticalAlignment="Center"/>
                    </Grid>
                    <Border Height="1" Background="{DynamicResource LineBrush}"/>
                    <Grid Margin="14,12">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8B7;" FontSize="16" Foreground="{DynamicResource MutedBrush}" Margin="0,0,11,0" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="1" x:Name="DataLabel" FontSize="12" Foreground="{DynamicResource MutedBrush}" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="2" x:Name="DataValue" FontSize="12" VerticalAlignment="Center"/>
                        <Ellipse Grid.Column="3" x:Name="DataDot" Width="6" Height="6" Margin="11,0,0,0" Fill="{DynamicResource MutedBrush}" VerticalAlignment="Center"/>
                    </Grid>
                </StackPanel>
            </Border>
            <Border Style="{StaticResource InfoTileStyle}" Margin="0,12,0,0">
                <StackPanel>
                    <DockPanel Margin="0,0,0,14">
                        <TextBlock x:Name="VersionStatusText" DockPanel.Dock="Right" Foreground="{DynamicResource MutedBrush}" FontSize="11"/>
                        <TextBlock x:Name="VersionHeading" FontSize="12" Foreground="{DynamicResource MutedBrush}"/>
                    </DockPanel>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock x:Name="ReleaseLabel" FontSize="11" Foreground="{DynamicResource MutedBrush}"/>
                            <TextBlock x:Name="ReleaseValue" Margin="0,4,0,0" FontSize="12" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                        <TextBlock Grid.Column="1" Text="&#x2192;" Foreground="{DynamicResource MutedBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        <StackPanel Grid.Column="2">
                            <TextBlock x:Name="TargetReleaseLabel" FontSize="11" Foreground="{DynamicResource MutedBrush}"/>
                            <TextBlock x:Name="TargetReleaseValue" Margin="0,4,0,0" FontSize="12" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Grid>
                </StackPanel>
            </Border>
            <Expander x:Name="TechnicalDetailsExpander" Style="{StaticResource DetailsExpanderStyle}" Margin="0,12,0,0" FontSize="12" IsExpanded="False">
                <StackPanel>
                    <TextBlock x:Name="ApplicationPathLabel" FontSize="11"/>
                    <TextBlock x:Name="ApplicationPathText" Style="{StaticResource DetailValueStyle}"/>
                    <TextBlock x:Name="DataPathLabel" FontSize="11"/>
                    <TextBlock x:Name="DataPathText" Style="{StaticResource DetailValueStyle}"/>
                    <DockPanel>
                        <TextBlock x:Name="DistributionValue" DockPanel.Dock="Right" FontSize="11"/>
                        <TextBlock x:Name="DistributionLabel" FontSize="11"/>
                    </DockPanel>
                    <TextBlock x:Name="DistributionPathText" Style="{StaticResource DetailValueStyle}"/>
                </StackPanel>
            </Expander>
            <Border BorderBrush="{DynamicResource LineBrush}" BorderThickness="0,1,0,0" Margin="0,15,0,0" Padding="0,12,0,0">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <WrapPanel VerticalAlignment="Center">
                        <Button x:Name="RefreshButton" Style="{StaticResource UtilityButtonStyle}" Tag="&#xE895;"/>
                        <Button x:Name="LogsButton" Style="{StaticResource UtilityButtonStyle}" Tag="&#xE8A5;"/>
                    </WrapPanel>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Width="1" Height="16" Background="{DynamicResource LineBrush}" Margin="4,0,7,0"/>
                        <StackPanel x:Name="RuntimeActionsPanel" Orientation="Horizontal">
                            <Button x:Name="RestartButton" Style="{StaticResource IconButtonStyle}" Tag="&#xE72C;"/>
                            <Button x:Name="StopButton" Style="{StaticResource DangerIconButtonStyle}" Tag="&#xE7E8;"/>
                        </StackPanel>
                        <Button x:Name="RepairButton" Style="{StaticResource IconButtonStyle}" Tag="&#xE90F;"/>
                    </StackPanel>
                </Grid>
            </Border>
            <TextBlock x:Name="LastCheckedText" Margin="1,10,0,0" FontSize="11" Foreground="{DynamicResource MutedBrush}"/>
        </StackPanel>
    </ScrollViewer>
</Window>
'@

    $xmlReader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    $xmlReader.Close()

    $names = @(
        "BrandLogo", "ConnectionsLabel", "TechnicalDetailsExpander", "VersionHeading", "VersionStatusText",
        "StateIconBadge", "StateIcon", "ApplicationDot", "DataDot", "ApplicationPathLabel", "ApplicationPathText", "DataPathLabel", "LastCheckedText",
        "SubtitleText", "StatusBadge", "StatusDot", "StatusBadgeText", "MainCard",
        "StateTitle", "StateDetail", "ApplicationLabel", "ApplicationValue",
        "DataLabel", "DataValue", "DataPathText", "DistributionLabel",
        "DistributionValue", "DistributionPathText", "ReleaseLabel", "ReleaseValue",
        "TargetReleaseLabel", "TargetReleaseValue",
        "BusyProgress", "BusyText", "ErrorBanner", "ErrorText", "StartButton",
        "UpdateButton", "OpenButton", "RuntimeActionsPanel", "RestartButton", "StopButton", "LogsButton", "RepairButton", "RefreshButton"
    )
    foreach ($name in $names) {
        $element = $window.FindName($name)
        if ($null -eq $element) { throw "The launcher layout is missing control: $name" }
        Set-Variable -Name $name -Value $element -Scope Script
    }

    function New-Brush {
        param([Parameter(Mandatory = $true)][string]$Color)
        return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    }

    $appearance = $Theme
    if ($appearance -eq "System") {
        $appearance = "Dark"
        try {
            $personalize = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop
            if ($personalize.AppsUseLightTheme -eq 1) { $appearance = "Light" }
        } catch { }
    }
    $script:launcherPalette = Get-LauncherThemePalette -Appearance $appearance
    if ([System.Windows.SystemParameters]::HighContrast) {
        foreach ($key in @('ShellBrush', 'SurfaceBrush', 'SoftBrush', 'SuccessSoftBrush', 'WarningSoftBrush', 'DangerSoftBrush')) {
            $script:launcherPalette[$key] = [System.Windows.SystemColors]::WindowColor.ToString()
        }
        foreach ($key in @('TextBrush', 'MutedBrush', 'SuccessBrush', 'WarningBrush', 'DangerBrush', 'LineBrush')) {
            $script:launcherPalette[$key] = [System.Windows.SystemColors]::WindowTextColor.ToString()
        }
        $script:launcherPalette.AccentBrush = [System.Windows.SystemColors]::HighlightColor.ToString()
        $script:launcherPalette.AccentHoverBrush = [System.Windows.SystemColors]::HighlightColor.ToString()
        $script:launcherPalette.AccentTextBrush = [System.Windows.SystemColors]::HighlightTextColor.ToString()
    }
    foreach ($key in $script:launcherPalette.Keys) { $window.Resources[$key] = New-Brush -Color $script:launcherPalette[$key] }

    # Fit short displays and enlarged Windows text without clipping the actions.
    $workHeight = [System.Windows.SystemParameters]::WorkArea.Height
    $window.MinHeight = [Math]::Min($window.MinHeight, $workHeight)
    $window.Height = [Math]::Min($window.Height, $workHeight)

    $window.Title = $text.WindowTitle
    $script:SubtitleText.Text = $text.Subtitle
    $script:ConnectionsLabel.Text = $text.Connections
    $script:TechnicalDetailsExpander.Header = $text.TechnicalDetails
    $script:VersionHeading.Text = $text.VersionHeading
    $script:ApplicationPathLabel.Text = $text.AppLabel
    $script:DataPathLabel.Text = $text.DataLabel
    $script:ApplicationLabel.Text = $text.AppLabel
    $script:DataLabel.Text = $text.DataLabel
    $script:DistributionLabel.Text = $text.DistributionLabel
    $script:ReleaseLabel.Text = $text.ReleaseLabel
    $script:TargetReleaseLabel.Text = $text.TargetReleaseLabel
    $script:StartButton.Content = $text.Start
    $script:UpdateButton.Content = $text.UpdateAndRestart
    $script:OpenButton.Content = $text.Open
    $script:RestartButton.Content = $text.Restart
    $script:StopButton.Content = $text.Stop
    $script:LogsButton.Content = $text.Logs
    $script:RepairButton.Content = $text.Repair
    $script:RefreshButton.Content = $text.Refresh
    foreach ($actionButton in @(
        $script:StartButton,
        $script:UpdateButton,
        $script:OpenButton,
        $script:RestartButton,
        $script:StopButton,
        $script:LogsButton,
        $script:RepairButton,
        $script:RefreshButton
    )) {
        $actionButton.ToolTip = ([string]$actionButton.Content).Replace("_", "")
    }

    $iconCandidates = @(
        (Join-Path -Path $launcherRoot -ChildPath "saphir-logo.png"),
        (Join-Path -Path $launcherRoot -ChildPath "app/frontend/assets/saphir-logo.png"),
        (Join-Path -Path $launcherRoot -ChildPath "SAPHIR.ico"),
        (Join-Path -Path $launcherRoot -ChildPath "deploy/bootstrap/SAPHIR.ico")
    )
    foreach ($iconPath in $iconCandidates) {
        if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
            try {
                # OnLoad releases the image file immediately, so launcher updates
                # never have to replace an image held open by this window.
                $imageStream = [IO.File]::OpenRead($iconPath)
                try {
                    $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create($imageStream,
                        [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                        [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                    $image = @($decoder.Frames | Sort-Object PixelWidth -Descending)[0]
                    $image.Freeze()
                    $script:BrandLogo.Source = $image
                    $window.Icon = $image
                } finally { $imageStream.Dispose() }
                break
            }
            catch {
            }
        }
    }

    if ($ValidateOnly) {
        if ($null -eq $script:BrandLogo.Source) { throw "The local SAPHIR logo could not be loaded." }
        $window.Measure([System.Windows.Size]::new($window.Width, $window.Height))
        $window.Arrange([System.Windows.Rect]::new(0, 0, $window.Width, $window.Height))
        Write-Host "SAPHIR launcher validation passed."
        return
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
        if ($Kind -eq "Status") {
            $script:ErrorBanner.Background = New-Brush -Color $script:launcherPalette.WarningSoftBrush
            $script:ErrorBanner.BorderBrush = New-Brush -Color $script:launcherPalette.WarningBrush
            $script:ErrorText.Foreground = New-Brush -Color $script:launcherPalette.WarningBrush
        }
        else {
            $script:ErrorBanner.Background = New-Brush -Color $script:launcherPalette.DangerSoftBrush
            $script:ErrorBanner.BorderBrush = New-Brush -Color $script:launcherPalette.DangerBrush
            $script:ErrorText.Foreground = New-Brush -Color $script:launcherPalette.DangerBrush
        }
        Set-Visible -Element $script:ErrorBanner -Visible $true
    }

    function Get-DeploymentIssueMessage {
        param([Parameter(Mandatory = $true)]$Status)

        $issue = [string]$Status.DeploymentIssue
        switch ($issue) {
            "DistributionUnavailable" {
                return ($text.DistributionUnavailable -f [string]$Status.DistributionRoot)
            }
            "ManifestUnavailable" {
                return ($text.ManifestUnavailable -f [string]$Status.ManifestPath)
            }
            "ManifestMissing" {
                return ($text.ManifestMissing -f [string]$Status.ManifestPath)
            }
            "ManifestUnreadable" { return $text.ManifestUnreadable }
            "ManifestFormatUnsupported" { return $text.ManifestUnsupported }
            "ReleaseIdInvalid" { return $text.ReleaseIdInvalid }
            "ChecksumInvalid" {
                return ($text.ChecksumInvalid -f [string]$Status.TargetReleaseId)
            }
            "PackagePathInvalid" {
                return ($text.PackagePathInvalid -f [string]$Status.TargetReleaseId)
            }
            "DataPathInvalid" {
                return ($text.DataPathInvalid -f [string]$Status.TargetReleaseId)
            }
            "PackageUnavailable" {
                return ($text.PackageUnavailable -f [string]$Status.TargetReleaseId, [string]$Status.TargetPackagePath)
            }
            "TargetDataUnavailable" {
                return ($text.TargetDataUnavailable -f [string]$Status.TargetReleaseId, [string]$Status.TargetDataFolderPath)
            }
            "TargetPreviouslyFailed" {
                return ($text.TargetPreviouslyFailed -f [string]$Status.TargetReleaseId)
            }
            default { return [string]$Status.DeploymentError }
        }
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
            $script:UpdateButton,
            $script:OpenButton,
            $script:RestartButton,
            $script:StopButton,
            $script:RepairButton,
            $script:RefreshButton
        )) {
            $button.IsEnabled = -not $Busy
        }
        if (-not $Busy -and $null -ne $script:lastStatus) {
            $script:StartButton.IsEnabled = [bool]$script:lastStatus.CanStart
            $script:OpenButton.IsEnabled = [bool]$script:lastStatus.CanOpen
            $script:RestartButton.IsEnabled = [bool]$script:lastStatus.CanRestart
            $script:StopButton.IsEnabled = [bool]$script:lastStatus.CanStop
            $script:UpdateButton.IsEnabled = [bool]$script:lastStatus.CanUpdate
            $script:RepairButton.IsEnabled = [bool]$script:lastStatus.CanRepair
        }
    }

    function Set-CheckingPresentation {
        $script:StatusBadge.Background = New-Brush -Color $script:launcherPalette.SoftBrush
        $script:StatusDot.Fill = New-Brush -Color $script:launcherPalette.MutedBrush
        $script:StatusBadgeText.Foreground = New-Brush -Color $script:launcherPalette.MutedBrush
        $script:StatusBadgeText.Text = $text.Checking
        $script:StateTitle.Text = $text.Checking
        $script:StateDetail.Text = ""
        $script:ApplicationValue.Text = "—"
        $script:DataValue.Text = "—"
        $script:DataPathText.Text = ""
        $script:DistributionValue.Text = "—"
        $script:DistributionPathText.Text = ""
        $script:ReleaseValue.Text = "—"
        $script:TargetReleaseValue.Text = "—"
        $script:VersionStatusText.Text = "—"
        $script:ApplicationPathText.Text = "—"
        $script:StateIcon.Text = [char]0xE72C
        foreach ($button in @($script:StartButton, $script:UpdateButton, $script:OpenButton, $script:RestartButton, $script:StopButton, $script:RepairButton)) {
            Set-Visible -Element $button -Visible $false
        }
        $script:StartButton.IsDefault = $false
        $script:UpdateButton.IsDefault = $false
        $script:OpenButton.IsDefault = $false
        Set-Visible -Element $script:RuntimeActionsPanel -Visible $false
    }

    function Apply-Status {
        param([Parameter(Mandatory = $true)]$Status)

        $script:lastStatus = $Status
        $state = [string]$Status.State
        $statusTitle = $text.Offline
        $heroTitle = $text.StoppedTitle
        $stateGlyph = [char]0xE768
        $detail = $text.OfflineDetail
        $dotColor = $script:launcherPalette.MutedBrush
        $badgeBackground = $script:launcherPalette.SoftBrush
        $badgeForeground = $script:launcherPalette.MutedBrush

        switch ($state) {
            "Online" {
                $statusTitle = $text.Online
                $heroTitle = $text.ReadyTitle
                $stateGlyph = [char]0xE73E
                $detail = $text.OnlineDetail
                $dotColor = $script:launcherPalette.SuccessBrush
                $badgeBackground = $script:launcherPalette.SuccessSoftBrush
                $badgeForeground = $script:launcherPalette.SuccessBrush
            }
            "Unresponsive" {
                $statusTitle = $text.Unresponsive
                $heroTitle = $text.Unresponsive
                $stateGlyph = [char]0xE7BA
                $detail = $text.UnresponsiveDetail
                $dotColor = $script:launcherPalette.WarningBrush
                $badgeBackground = $script:launcherPalette.WarningSoftBrush
                $badgeForeground = $script:launcherPalette.WarningBrush
            }
            "PortConflict" {
                $statusTitle = $text.Conflict
                $heroTitle = $text.Conflict
                $stateGlyph = [char]0xE783
                $detail = $text.ConflictDetail
                $dotColor = $script:launcherPalette.DangerBrush
                $badgeBackground = $script:launcherPalette.DangerSoftBrush
                $badgeForeground = $script:launcherPalette.DangerBrush
            }
            default {
                if ([string]::IsNullOrWhiteSpace([string]$Status.ReleaseId) -and
                    -not [bool]$Status.DistributionAvailable) {
                    $detail = $text.NeedsNetwork
                }
            }
        }

        if ([bool]$Status.UpdateAvailable -and -not [bool]$Status.TargetPreviouslyFailed) {
            $updateDetail = if ([bool]$Status.CanStart) {
                $text.UpdateOnStart -f [string]$Status.TargetReleaseId
            }
            else {
                $text.UpdateOnRestart -f [string]$Status.TargetReleaseId
            }
            $detail = "$detail $updateDetail"
            if ($state -eq "Online" -or $state -eq "Offline") {
                $heroTitle = $text.UpdateTitle
                $stateGlyph = [char]0xE895
            }
        }

        if (($state -eq "Online" -or $state -eq "Offline") -and
            -not [string]::IsNullOrWhiteSpace([string]$Status.DataFolderPath) -and -not [bool]$Status.DataAvailable) {
            $heroTitle = $text.NetworkTitle
            $detail = $text.NetworkDetail
            $stateGlyph = [char]0xE7BA
        }

        $script:StatusBadge.Background = New-Brush -Color $badgeBackground
        $script:StatusDot.Fill = New-Brush -Color $dotColor
        $script:StatusBadgeText.Foreground = New-Brush -Color $badgeForeground
        $script:StatusBadgeText.Text = $statusTitle
        $script:StateTitle.Text = $heroTitle
        $script:StateDetail.Text = $detail
        $script:ApplicationValue.Text = $statusTitle
        $script:ApplicationDot.Fill = New-Brush -Color $dotColor
        $script:StateIcon.Text = $stateGlyph
        $script:StateIconBadge.Background = New-Brush -Color $badgeBackground
        $script:StateIcon.Foreground = New-Brush -Color $badgeForeground
        if ($heroTitle -eq $text.NetworkTitle -or $heroTitle -eq $text.UpdateTitle) {
            $script:StateIconBadge.Background = New-Brush -Color $script:launcherPalette.WarningSoftBrush
            $script:StateIcon.Foreground = New-Brush -Color $script:launcherPalette.WarningBrush
        }
        $script:ApplicationPathText.Text = [string]$Status.FrontendUrl
        $script:ApplicationPathText.ToolTip = [string]$Status.FrontendUrl
        $script:LastCheckedText.Text = $text.LastChecked -f (Get-Date -Format 'HH:mm')

        $dataPath = [string]$Status.DataFolderPath
        if ([string]::IsNullOrWhiteSpace($dataPath)) {
            $script:DataValue.Text = $text.NotConfigured
            $script:DataValue.Foreground = New-Brush -Color $script:launcherPalette.MutedBrush
            $script:DataPathText.Text = ""
            $script:DataPathText.ToolTip = $null
        }
        elseif ([bool]$Status.DataAvailable) {
            $script:DataValue.Text = $text.Available
            $script:DataValue.Foreground = New-Brush -Color $script:launcherPalette.SuccessBrush
            $script:DataPathText.Text = $dataPath
            $script:DataPathText.ToolTip = $dataPath
        }
        else {
            $script:DataValue.Text = $text.Unavailable
            $script:DataValue.Foreground = New-Brush -Color $script:launcherPalette.WarningBrush
            $script:DataPathText.Text = $dataPath
            $script:DataPathText.ToolTip = $dataPath
        }
        $script:DataDot.Fill = $script:DataValue.Foreground

        $distributionPath = [string]$Status.DistributionRoot
        $script:DistributionPathText.Text = $distributionPath
        $script:DistributionPathText.ToolTip = $distributionPath
        if ([string]$Status.DeploymentState -eq "Development") {
            $script:DistributionValue.Text = $text.Development
            $script:DistributionValue.Foreground = New-Brush -Color $script:launcherPalette.MutedBrush
        }
        elseif ([string]$Status.DeploymentState -eq "Ready") {
            $script:DistributionValue.Text = $text.Available
            $script:DistributionValue.Foreground = New-Brush -Color $script:launcherPalette.SuccessBrush
        }
        elseif ([bool]$Status.DistributionReachable) {
            $script:DistributionValue.Text = $text.NeedsAttention
            $script:DistributionValue.Foreground = New-Brush -Color $script:launcherPalette.WarningBrush
        }
        else {
            $script:DistributionValue.Text = $text.Unavailable
            $script:DistributionValue.Foreground = New-Brush -Color $script:launcherPalette.WarningBrush
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

        $targetReleaseId = [string]$Status.TargetReleaseId
        if ([string]::IsNullOrWhiteSpace($targetReleaseId)) {
            $script:TargetReleaseValue.Text = "—"
            $script:TargetReleaseValue.ToolTip = $null
            $script:TargetReleaseValue.Foreground = New-Brush -Color $script:launcherPalette.MutedBrush
            $script:VersionStatusText.Text = $text.Unavailable
        }
        elseif ([bool]$Status.TargetPreviouslyFailed) {
            $targetDisplay = "{0} · {1}" -f $targetReleaseId, $text.PreviousFailure
            $script:TargetReleaseValue.Text = $targetReleaseId
            $script:TargetReleaseValue.ToolTip = $targetDisplay
            $script:TargetReleaseValue.Foreground = New-Brush -Color $script:launcherPalette.WarningBrush
            $script:VersionStatusText.Text = $text.PreviousFailure
        }
        elseif ([bool]$Status.UpdateAvailable) {
            $targetDisplay = "{0} · {1}" -f $targetReleaseId, $text.UpdateAvailable
            $script:TargetReleaseValue.Text = $targetReleaseId
            $script:TargetReleaseValue.ToolTip = $targetDisplay
            $script:TargetReleaseValue.Foreground = New-Brush -Color $script:launcherPalette.AccentBrush
            $script:VersionStatusText.Text = $text.UpdateAvailable
        }
        else {
            $targetDisplay = "{0} · {1}" -f $targetReleaseId, $text.CurrentRelease
            $script:TargetReleaseValue.Text = $targetReleaseId
            $script:TargetReleaseValue.ToolTip = $targetDisplay
            $script:TargetReleaseValue.Foreground = New-Brush -Color $script:launcherPalette.SuccessBrush
            $script:VersionStatusText.Text = $text.CurrentRelease
        }
        $script:VersionStatusText.Foreground = $script:TargetReleaseValue.Foreground

        $deploymentMessage = Get-DeploymentIssueMessage -Status $Status
        if (-not [string]::IsNullOrWhiteSpace($deploymentMessage)) {
            if ($script:errorKind -ne "Action" -and $script:errorKind -ne "User") {
                Show-Error -Message $deploymentMessage -Kind "Status"
            }
        }
        elseif ($script:errorKind -eq "Status") {
            Hide-Error
        }

        $showUpdate = [bool]$Status.CanUpdate
        $script:UpdateButton.Content = if ($state -eq "Offline") { $text.UpdateAndStart } else { $text.UpdateAndRestart }
        $script:UpdateButton.ToolTip = ([string]$script:UpdateButton.Content).Replace("_", "")
        Set-Visible -Element $script:StartButton -Visible ($state -eq "Offline" -and -not $showUpdate)
        Set-Visible -Element $script:UpdateButton -Visible $showUpdate
        Set-Visible -Element $script:OpenButton -Visible ($state -eq "Online" -and -not $showUpdate)
        Set-Visible -Element $script:RestartButton -Visible (($state -eq "Online" -or $state -eq "Unresponsive") -and -not $showUpdate)
        Set-Visible -Element $script:StopButton -Visible ($state -eq "Online" -or $state -eq "Unresponsive")
        Set-Visible -Element $script:RuntimeActionsPanel -Visible ($state -eq "Online" -or $state -eq "Unresponsive")
        Set-Visible -Element $script:RepairButton -Visible ([bool]$Status.CanRepair)
        $script:StartButton.IsDefault = ($state -eq "Offline" -and -not $showUpdate)
        $script:UpdateButton.IsDefault = $showUpdate
        $script:OpenButton.IsDefault = ($state -eq "Online" -and -not $showUpdate)

        if (-not $script:actionBusy) {
            $script:StartButton.IsEnabled = [bool]$Status.CanStart
            $script:OpenButton.IsEnabled = [bool]$Status.CanOpen
            $script:RestartButton.IsEnabled = [bool]$Status.CanRestart
            $script:StopButton.IsEnabled = [bool]$Status.CanStop
            $script:UpdateButton.IsEnabled = [bool]$Status.CanUpdate
            $script:RepairButton.IsEnabled = [bool]$Status.CanRepair
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
        param([Parameter(Mandatory = $true)][ValidateSet("Start", "Restart", "Stop", "Update", "Repair")][string]$Action)

        if ($script:closing -or $null -ne $script:actionWorker) {
            return
        }

        Hide-Error
        $busyMessage = switch ($Action) {
            "Start" { $text.Starting }
            "Restart" { $text.Restarting }
            "Update" { $text.Updating }
            "Repair" { $text.Repairing }
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
                Hide-Error
                Apply-Status -Status $status
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
    $script:UpdateButton.Add_Click({ Start-LauncherAction -Action "Update" })
    $script:RestartButton.Add_Click({ Start-LauncherAction -Action "Restart" })
    $script:StopButton.Add_Click({ Start-LauncherAction -Action "Stop" })
    $script:RefreshButton.Add_Click({
        Hide-Error
        Start-StatusRefresh -ShowProgress
    })
    $script:RepairButton.Add_Click({ Start-LauncherAction -Action "Repair" })
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
