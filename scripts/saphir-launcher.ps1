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
            Subtitle          = "Démarrage et état local"
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
            OnlineDetail      = "SAPHIR répond normalement et peut être ouvert."
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
            Subtitle          = "Local status and startup"
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
            OnlineDetail      = "SAPHIR is responding normally and is ready to open."
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

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="LauncherWindow"
        Width="570"
        Height="680"
        MinWidth="570"
        MinHeight="680"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen"
        Background="#F4F6F9"
        FontFamily="Segoe UI"
        FontSize="14"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
    <Window.Resources>
        <Style x:Key="BaseButtonStyle" TargetType="{x:Type Button}">
            <Setter Property="MinHeight" Value="40"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Margin" Value="0"/>
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
                                CornerRadius="9"
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
            <Setter Property="MinHeight" Value="46"/>
            <Setter Property="FontSize" Value="15"/>
            <Setter Property="Background" Value="#0071E3"/>
            <Setter Property="BorderBrush" Value="#0071E3"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="ButtonBorder"
                                CornerRadius="11"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                                <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="17"
                                           Text="{TemplateBinding Tag}" Margin="0,0,10,0"
                                           VerticalAlignment="Center"/>
                                <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/>
                            </StackPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#0A7BEA"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#005FC1"/>
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
        <Style x:Key="IconButtonStyle" TargetType="{x:Type Button}">
            <Setter Property="Width" Value="88"/>
            <Setter Property="Height" Value="58"/>
            <Setter Property="Padding" Value="6,7"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Normal"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Background" Value="#F6F7F9"/>
            <Setter Property="BorderBrush" Value="#E1E4E8"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="#36383D"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="ButtonBorder"
                                CornerRadius="10"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                                <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="18"
                                           Text="{TemplateBinding Tag}" HorizontalAlignment="Center"/>
                                <ContentPresenter Margin="0,5,0,0" HorizontalAlignment="Center"
                                                  VerticalAlignment="Center" RecognizesAccessKey="True"/>
                            </StackPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#EDF3FA"/>
                                <Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#C9DDF3"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="#DFEAF6"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.38"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DangerIconButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource IconButtonStyle}">
            <Setter Property="Foreground" Value="#C5312D"/>
            <Setter Property="Background" Value="#FFF8F7"/>
            <Setter Property="BorderBrush" Value="#F1D7D5"/>
        </Style>
        <Style x:Key="UtilityButtonStyle" TargetType="{x:Type Button}" BasedOn="{StaticResource IconButtonStyle}"/>
        <Style x:Key="InfoTileStyle" TargetType="{x:Type Border}">
            <Setter Property="Background" Value="#F7F8FA"/>
            <Setter Property="BorderBrush" Value="#E8EAED"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="10"/>
            <Setter Property="Padding" Value="12,10"/>
        </Style>
    </Window.Resources>
    <Grid Margin="24,22,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="16"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="14"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border Width="44" Height="44" CornerRadius="12" Background="#0071E3">
                <TextBlock Text="S" Foreground="White" FontSize="22" FontWeight="Bold"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="2" VerticalAlignment="Center">
                <TextBlock Text="SAPHIR" FontSize="22" FontWeight="SemiBold" Foreground="#17191C"/>
                <TextBlock x:Name="SubtitleText" Margin="0,2,0,0" FontSize="12" Foreground="#71757B"/>
            </StackPanel>
            <Border Grid.Column="3" x:Name="StatusBadge" CornerRadius="14" Padding="11,6"
                    Background="#EFEFF4" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#8E8E93"
                             Margin="0,0,7,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="StatusBadgeText" FontSize="12" FontWeight="SemiBold"
                               Foreground="#3A3A3C"/>
                </StackPanel>
            </Border>
        </Grid>

        <Border Grid.Row="2" x:Name="MainCard" Background="White" BorderBrush="#E0E3E7"
                BorderThickness="1" CornerRadius="16" Padding="20">
            <Border.Effect>
                <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.07" Color="#000000"/>
            </Border.Effect>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="16"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="10"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="14"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" x:Name="StateTitle" FontSize="21" FontWeight="SemiBold"
                           Foreground="#17191C"/>
                <TextBlock Grid.Row="1" x:Name="StateDetail" Margin="0,5,0,0" Foreground="#656A70"
                           TextWrapping="Wrap" MinHeight="34"/>

                <Grid Grid.Row="3">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Style="{StaticResource InfoTileStyle}">
                        <StackPanel>
                            <TextBlock x:Name="ApplicationLabel" FontSize="11" Foreground="#777B81"/>
                            <TextBlock x:Name="ApplicationValue" Margin="0,4,0,0" FontWeight="SemiBold"
                                       Foreground="#17191C" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Border>
                    <Border Grid.Column="2" Style="{StaticResource InfoTileStyle}">
                        <StackPanel>
                            <TextBlock x:Name="DataLabel" FontSize="11" Foreground="#777B81"/>
                            <TextBlock x:Name="DataValue" Margin="0,4,0,0" FontWeight="SemiBold"
                                       Foreground="#17191C" TextTrimming="CharacterEllipsis"/>
                            <TextBlock x:Name="DataPathText" Margin="0,2,0,0" FontSize="10"
                                       Foreground="#92969C" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <Grid Grid.Row="5">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Style="{StaticResource InfoTileStyle}">
                        <StackPanel>
                            <TextBlock x:Name="ReleaseLabel" FontSize="11" Foreground="#777B81"/>
                            <TextBlock x:Name="ReleaseValue" Margin="0,4,0,0" FontWeight="SemiBold"
                                       Foreground="#17191C" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Border>
                    <Border Grid.Column="2" Style="{StaticResource InfoTileStyle}">
                        <StackPanel>
                            <TextBlock x:Name="TargetReleaseLabel" FontSize="11" Foreground="#777B81"/>
                            <TextBlock x:Name="TargetReleaseValue" Margin="0,4,0,0" FontWeight="SemiBold"
                                       Foreground="#17191C" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Border>
                </Grid>

                <Border Grid.Row="7" Style="{StaticResource InfoTileStyle}" Padding="12,9">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock x:Name="DistributionLabel" FontSize="11" Foreground="#777B81"/>
                            <TextBlock x:Name="DistributionPathText" Margin="0,3,14,0" FontSize="10"
                                       Foreground="#92969C" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                        <TextBlock Grid.Column="1" x:Name="DistributionValue" FontSize="12"
                                   FontWeight="SemiBold" Foreground="#17191C" VerticalAlignment="Center"/>
                    </Grid>
                </Border>

                <ProgressBar Grid.Row="8" x:Name="BusyProgress" Margin="0,12,0,0" Height="3"
                             IsIndeterminate="True" Visibility="Collapsed"
                             Foreground="#0071E3" Background="#E5E5EA"/>
                <TextBlock Grid.Row="9" x:Name="BusyText" Margin="0,6,0,0"
                           FontSize="12" Foreground="#656A70" Visibility="Collapsed"/>
                <Border Grid.Row="10" x:Name="ErrorBanner" Margin="0,9,0,0"
                        Padding="11,8" CornerRadius="8" Background="#FFF1F0"
                        BorderBrush="#FFD0CC" BorderThickness="1" Visibility="Collapsed">
                    <TextBlock x:Name="ErrorText" FontSize="12" Foreground="#A51C14" TextWrapping="Wrap"/>
                </Border>
            </Grid>
        </Border>

        <Border Grid.Row="4" Background="White" BorderBrush="#E0E3E7" BorderThickness="1"
                CornerRadius="14" Padding="14,13">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="10"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0">
                    <Button x:Name="StartButton" Style="{StaticResource PrimaryButtonStyle}"
                            Tag="&#xE768;" Width="300" HorizontalAlignment="Center"/>
                    <Button x:Name="UpdateButton" Style="{StaticResource PrimaryButtonStyle}"
                            Tag="&#xE895;" Width="300" HorizontalAlignment="Center"/>
                    <Button x:Name="OpenButton" Style="{StaticResource PrimaryButtonStyle}"
                            Tag="&#xE8A7;" Width="300" HorizontalAlignment="Center"/>
                </Grid>
                <StackPanel Grid.Row="2" x:Name="ActionToolbar" Orientation="Horizontal"
                            HorizontalAlignment="Center">
                    <StackPanel x:Name="RuntimeActionsPanel" Orientation="Horizontal">
                        <Button x:Name="RestartButton" Style="{StaticResource IconButtonStyle}"
                                Tag="&#xE72C;" Margin="0,0,7,0"/>
                        <Button x:Name="StopButton" Style="{StaticResource DangerIconButtonStyle}"
                                Tag="&#xE71A;" Margin="0,0,7,0"/>
                    </StackPanel>
                    <Button x:Name="LogsButton" Style="{StaticResource UtilityButtonStyle}"
                            Tag="&#xE8B7;" Margin="0,0,7,0"/>
                    <Button x:Name="RepairButton" Style="{StaticResource UtilityButtonStyle}"
                            Tag="&#xE90F;" Margin="0,0,7,0"/>
                    <Button x:Name="RefreshButton" Style="{StaticResource UtilityButtonStyle}"
                            Tag="&#xE895;"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

    $xmlReader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
    $xmlReader.Close()

    $names = @(
        "SubtitleText", "StatusBadge", "StatusDot", "StatusBadgeText", "MainCard",
        "StateTitle", "StateDetail", "ApplicationLabel", "ApplicationValue",
        "DataLabel", "DataValue", "DataPathText", "DistributionLabel",
        "DistributionValue", "DistributionPathText", "ReleaseLabel", "ReleaseValue",
        "TargetReleaseLabel", "TargetReleaseValue",
        "BusyProgress", "BusyText", "ErrorBanner", "ErrorText", "StartButton",
        "UpdateButton", "OpenButton", "RuntimeActionsPanel", "RestartButton", "StopButton", "LogsButton", "RepairButton", "RefreshButton"
    )
    foreach ($name in $names) {
        Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
    }

    $window.Title = $text.WindowTitle
    $script:SubtitleText.Text = $text.Subtitle
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
        if ($Kind -eq "Status") {
            $script:ErrorBanner.Background = New-Brush -Color "#FFF6E5"
            $script:ErrorBanner.BorderBrush = New-Brush -Color "#FFD59A"
            $script:ErrorText.Foreground = New-Brush -Color "#8A4B00"
        }
        else {
            $script:ErrorBanner.Background = New-Brush -Color "#FFF1F0"
            $script:ErrorBanner.BorderBrush = New-Brush -Color "#FFD0CC"
            $script:ErrorText.Foreground = New-Brush -Color "#A51C14"
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
        $script:StatusBadge.Background = New-Brush -Color "#EFEFF4"
        $script:StatusDot.Fill = New-Brush -Color "#8E8E93"
        $script:StatusBadgeText.Foreground = New-Brush -Color "#3A3A3C"
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

        if ([bool]$Status.UpdateAvailable -and -not [bool]$Status.TargetPreviouslyFailed) {
            $updateDetail = if ([bool]$Status.CanStart) {
                $text.UpdateOnStart -f [string]$Status.TargetReleaseId
            }
            else {
                $text.UpdateOnRestart -f [string]$Status.TargetReleaseId
            }
            $detail = "$detail $updateDetail"
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

        $distributionPath = [string]$Status.DistributionRoot
        $script:DistributionPathText.Text = $distributionPath
        $script:DistributionPathText.ToolTip = $distributionPath
        if ([string]$Status.DeploymentState -eq "Development") {
            $script:DistributionValue.Text = $text.Development
            $script:DistributionValue.Foreground = New-Brush -Color "#8E8E93"
        }
        elseif ([string]$Status.DeploymentState -eq "Ready") {
            $script:DistributionValue.Text = $text.Available
            $script:DistributionValue.Foreground = New-Brush -Color "#248A3D"
        }
        elseif ([bool]$Status.DistributionReachable) {
            $script:DistributionValue.Text = $text.NeedsAttention
            $script:DistributionValue.Foreground = New-Brush -Color "#B25000"
        }
        else {
            $script:DistributionValue.Text = $text.Unavailable
            $script:DistributionValue.Foreground = New-Brush -Color "#B25000"
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
            $script:TargetReleaseValue.Foreground = New-Brush -Color "#8E8E93"
        }
        elseif ([bool]$Status.TargetPreviouslyFailed) {
            $targetDisplay = "{0} · {1}" -f $targetReleaseId, $text.PreviousFailure
            $script:TargetReleaseValue.Text = $targetDisplay
            $script:TargetReleaseValue.ToolTip = $targetDisplay
            $script:TargetReleaseValue.Foreground = New-Brush -Color "#B25000"
        }
        elseif ([bool]$Status.UpdateAvailable) {
            $targetDisplay = "{0} · {1}" -f $targetReleaseId, $text.UpdateAvailable
            $script:TargetReleaseValue.Text = $targetDisplay
            $script:TargetReleaseValue.ToolTip = $targetDisplay
            $script:TargetReleaseValue.Foreground = New-Brush -Color "#0071E3"
        }
        else {
            $targetDisplay = "{0} · {1}" -f $targetReleaseId, $text.CurrentRelease
            $script:TargetReleaseValue.Text = $targetDisplay
            $script:TargetReleaseValue.ToolTip = $targetDisplay
            $script:TargetReleaseValue.Foreground = New-Brush -Color "#248A3D"
        }

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
