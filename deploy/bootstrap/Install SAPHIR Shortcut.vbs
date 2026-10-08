Option Explicit

Dim shell
Dim fso
Dim distributionRoot
Dim sourceLauncherEntryPath
Dim sourceLauncherHostPath
Dim sourceLauncherVersionPath
Dim sourceLauncherScriptPath
Dim sourceLauncherControlPath
Dim sourceApplicationLayoutPath
Dim sourceCachedLaunchPath
Dim sourceLocalCachePath
Dim sourceServerControlPath
Dim sourceIconPath
Dim localAppData
Dim localRoot
Dim localAssetsRoot
Dim localIconPath
Dim localLauncherRoot
Dim localLauncherVersionsRoot
Dim stagingRoot
Dim stagingScriptsRoot
Dim stagingLibraryRoot
Dim bundleId
Dim bundleBaseId
Dim bundleCandidate
Dim bundleSequence
Dim bundleRoot
Dim localLauncherEntryPath
Dim localLauncherHostPath
Dim localLauncherPointerPath
Dim localLauncherVersionPath
Dim localBundleIconPath
Dim localLauncherScriptPath
Dim localLauncherControlPath
Dim localApplicationLayoutPath
Dim localCachedLaunchPath
Dim localLocalCachePath
Dim localServerControlPath
Dim distributionRootFilePath
Dim distributionRootFile
Dim failedReleasePath
Dim failedReleaseReset
Dim desktopPath
Dim shortcutPath
Dim shortcut
Dim copyError
Dim copyErrorDescription
Dim confirmationMessage
Dim silentInstall
Dim installerArgument
Dim pointerFile
Dim stableDistributionRootFile
Dim windowsScriptHost

Sub EnsureFolder(folderPath)
    If Not fso.FolderExists(folderPath) Then
        On Error Resume Next
        fso.CreateFolder folderPath
        copyError = Err.Number
        copyErrorDescription = Err.Description
        Err.Clear
        On Error GoTo 0
        If copyError <> 0 Then
            If Len(stagingRoot) > 0 And fso.FolderExists(stagingRoot) Then
                On Error Resume Next
                fso.DeleteFolder stagingRoot, True
                On Error GoTo 0
            End If
            shell.Popup "SAPHIR could not create its local launcher folder." & vbCrLf & copyErrorDescription, 0, "SAPHIR", 16
            WScript.Quit 1
        End If
    End If
End Sub

Function InvalidateFailedReleaseMarker(markerPath)
    Dim attempt

    InvalidateFailedReleaseMarker = True
    If Not fso.FileExists(markerPath) Then
        Exit Function
    End If

    ' A failed release is normally skipped until its package hash changes. A
    ' freshly installed launcher bundle may contain the compatibility fix that
    ' makes that exact release usable, so an explicit reinstall is also an
    ' explicit request to retry it. Wait briefly in case another launcher has
    ' just finished reading the marker.
    For attempt = 1 To 5
        On Error Resume Next
        fso.DeleteFile markerPath, True
        copyError = Err.Number
        copyErrorDescription = Err.Description
        Err.Clear
        On Error GoTo 0

        If Not fso.FileExists(markerPath) Then
            Exit Function
        End If
        WScript.Sleep 200
    Next

    InvalidateFailedReleaseMarker = False
End Function

Sub CopyLauncherFile(sourcePath, destinationPath, displayName)
    On Error Resume Next
    fso.CopyFile sourcePath, destinationPath, True
    copyError = Err.Number
    copyErrorDescription = Err.Description
    Err.Clear
    On Error GoTo 0
    If copyError <> 0 Then
        If Len(stagingRoot) > 0 And fso.FolderExists(stagingRoot) Then
            On Error Resume Next
            fso.DeleteFolder stagingRoot, True
            On Error GoTo 0
        End If
        shell.Popup "SAPHIR could not install " & displayName & " in local AppData." & vbCrLf & copyErrorDescription, 0, "SAPHIR", 16
        WScript.Quit 1
    End If
End Sub

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

distributionRoot = fso.GetAbsolutePathName(fso.GetParentFolderName(WScript.ScriptFullName))
sourceLauncherEntryPath = fso.BuildPath(distributionRoot, "SAPHIR Launcher.vbs")
sourceLauncherHostPath = fso.BuildPath(distributionRoot, "SAPHIR Launcher Host.vbs")
sourceLauncherVersionPath = fso.BuildPath(distributionRoot, "launcher-version.txt")
sourceLauncherScriptPath = fso.BuildPath(distributionRoot, "scripts\saphir-launcher.ps1")
sourceLauncherControlPath = fso.BuildPath(distributionRoot, "scripts\lib\LauncherControl.ps1")
sourceApplicationLayoutPath = fso.BuildPath(distributionRoot, "scripts\lib\ApplicationLayout.ps1")
sourceCachedLaunchPath = fso.BuildPath(distributionRoot, "scripts\launch-cached-app.ps1")
sourceLocalCachePath = fso.BuildPath(distributionRoot, "scripts\lib\LocalAppCache.ps1")
sourceServerControlPath = fso.BuildPath(distributionRoot, "scripts\lib\ServerControl.ps1")
sourceIconPath = fso.BuildPath(distributionRoot, "SAPHIR.ico")

If Not fso.FileExists(sourceLauncherEntryPath) Then
    shell.Popup "SAPHIR Launcher.vbs is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

If Not fso.FileExists(sourceLauncherHostPath) Then
    shell.Popup "SAPHIR Launcher Host.vbs is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

If Not fso.FileExists(sourceLauncherVersionPath) Then
    shell.Popup "launcher-version.txt is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

If Not fso.FileExists(sourceLauncherScriptPath) Then
    shell.Popup "scripts\saphir-launcher.ps1 is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

If Not fso.FileExists(sourceLauncherControlPath) Then
    shell.Popup "scripts\lib\LauncherControl.ps1 is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

If Not fso.FileExists(sourceApplicationLayoutPath) Then
    shell.Popup "scripts\lib\ApplicationLayout.ps1 is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

If Not fso.FileExists(sourceCachedLaunchPath) Then
    shell.Popup "scripts\launch-cached-app.ps1 is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

If Not fso.FileExists(sourceLocalCachePath) Then
    shell.Popup "scripts\lib\LocalAppCache.ps1 is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

If Not fso.FileExists(sourceServerControlPath) Then
    shell.Popup "scripts\lib\ServerControl.ps1 is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

If Not fso.FileExists(sourceIconPath) Then
    shell.Popup "SAPHIR.ico is missing from the distribution folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

localAppData = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%")
If Len(localAppData) = 0 Or InStr(localAppData, "%") > 0 Then
    localAppData = shell.ExpandEnvironmentStrings("%TEMP%")
End If
If Len(localAppData) = 0 Or InStr(localAppData, "%") > 0 Then
    shell.Popup "SAPHIR could not locate local AppData on this computer.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

localRoot = fso.BuildPath(localAppData, "SAPHIR")
localAssetsRoot = fso.BuildPath(localRoot, "assets")
localLauncherRoot = fso.BuildPath(localRoot, "launcher")
localLauncherVersionsRoot = fso.BuildPath(localLauncherRoot, "versions")
localLauncherHostPath = fso.BuildPath(localLauncherRoot, "SAPHIR Launcher.vbs")
localLauncherPointerPath = fso.BuildPath(localLauncherRoot, "current.txt")
localLauncherVersionPath = fso.BuildPath(localLauncherRoot, "launcher-version.txt")

EnsureFolder localRoot
EnsureFolder localAssetsRoot
EnsureFolder localLauncherRoot
EnsureFolder localLauncherVersionsRoot

localIconPath = fso.BuildPath(localAssetsRoot, "SAPHIR.ico")
bundleBaseId = CStr(Year(Now)) & Right("0" & CStr(Month(Now)), 2) & Right("0" & CStr(Day(Now)), 2) & "-" & _
    Right("0" & CStr(Hour(Now)), 2) & Right("0" & CStr(Minute(Now)), 2) & Right("0" & CStr(Second(Now)), 2)
bundleSequence = 1
Do
    bundleCandidate = bundleBaseId
    If bundleSequence > 1 Then
        bundleCandidate = bundleBaseId & "-" & CStr(bundleSequence)
    End If
    stagingRoot = fso.BuildPath(localLauncherRoot, ".staging-" & bundleCandidate)
    bundleRoot = fso.BuildPath(localLauncherVersionsRoot, bundleCandidate)
    If Not fso.FolderExists(stagingRoot) And Not fso.FolderExists(bundleRoot) Then
        Exit Do
    End If
    bundleSequence = bundleSequence + 1
Loop
bundleId = bundleCandidate
stagingScriptsRoot = fso.BuildPath(stagingRoot, "scripts")
stagingLibraryRoot = fso.BuildPath(stagingScriptsRoot, "lib")

EnsureFolder stagingRoot
EnsureFolder stagingScriptsRoot
EnsureFolder stagingLibraryRoot

localLauncherEntryPath = fso.BuildPath(stagingRoot, "SAPHIR Launcher.vbs")
localBundleIconPath = fso.BuildPath(stagingRoot, "SAPHIR.ico")
localLauncherScriptPath = fso.BuildPath(stagingScriptsRoot, "saphir-launcher.ps1")
localLauncherControlPath = fso.BuildPath(stagingLibraryRoot, "LauncherControl.ps1")
localApplicationLayoutPath = fso.BuildPath(stagingLibraryRoot, "ApplicationLayout.ps1")
localCachedLaunchPath = fso.BuildPath(stagingScriptsRoot, "launch-cached-app.ps1")
localLocalCachePath = fso.BuildPath(stagingLibraryRoot, "LocalAppCache.ps1")
localServerControlPath = fso.BuildPath(stagingLibraryRoot, "ServerControl.ps1")
distributionRootFilePath = fso.BuildPath(stagingRoot, "distribution-root.txt")

CopyLauncherFile sourceLauncherScriptPath, localLauncherScriptPath, "the launcher interface"
CopyLauncherFile sourceLauncherControlPath, localLauncherControlPath, "the launcher controller"
CopyLauncherFile sourceApplicationLayoutPath, localApplicationLayoutPath, "the application layout resolver"
CopyLauncherFile sourceCachedLaunchPath, localCachedLaunchPath, "the cached application starter"
CopyLauncherFile sourceLocalCachePath, localLocalCachePath, "the local application cache support"
CopyLauncherFile sourceServerControlPath, localServerControlPath, "the local service controller"
CopyLauncherFile sourceIconPath, localBundleIconPath, "the launcher icon"
CopyLauncherFile sourceLauncherEntryPath, localLauncherEntryPath, "the launcher"
CopyLauncherFile sourceLauncherVersionPath, fso.BuildPath(stagingRoot, "launcher-version.txt"), "the launcher version"

' Write Unicode so mapped paths containing French accents remain intact.
On Error Resume Next
Set distributionRootFile = fso.CreateTextFile(distributionRootFilePath, True, True)
If Err.Number = 0 Then
    distributionRootFile.WriteLine distributionRoot
    distributionRootFile.Close
End If
copyError = Err.Number
copyErrorDescription = Err.Description
Err.Clear
On Error GoTo 0
If copyError <> 0 Then
    If fso.FolderExists(stagingRoot) Then
        On Error Resume Next
        fso.DeleteFolder stagingRoot, True
        On Error GoTo 0
    End If
    shell.Popup "SAPHIR could not save the distribution location in local AppData." & vbCrLf & copyErrorDescription, 0, "SAPHIR", 16
    WScript.Quit 1
End If

' Validate the complete staged bundle before one same-volume directory rename.
If Not fso.FileExists(localLauncherEntryPath) Or _
   Not fso.FileExists(localBundleIconPath) Or _
   Not fso.FileExists(localLauncherScriptPath) Or _
   Not fso.FileExists(localLauncherControlPath) Or _
   Not fso.FileExists(localApplicationLayoutPath) Or _
   Not fso.FileExists(localCachedLaunchPath) Or _
   Not fso.FileExists(localLocalCachePath) Or _
   Not fso.FileExists(localServerControlPath) Or _
   Not fso.FileExists(fso.BuildPath(stagingRoot, "launcher-version.txt")) Or _
   Not fso.FileExists(distributionRootFilePath) Then
    fso.DeleteFolder stagingRoot, True
    shell.Popup "The local SAPHIR launcher bundle could not be validated.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

On Error Resume Next
fso.MoveFolder stagingRoot, bundleRoot
copyError = Err.Number
copyErrorDescription = Err.Description
Err.Clear
On Error GoTo 0
If copyError <> 0 Then
    If fso.FolderExists(stagingRoot) Then
        On Error Resume Next
        fso.DeleteFolder stagingRoot, True
        On Error GoTo 0
    End If
    shell.Popup "SAPHIR could not activate its local launcher bundle." & vbCrLf & copyErrorDescription, 0, "SAPHIR", 16
    WScript.Quit 1
End If

localLauncherEntryPath = fso.BuildPath(bundleRoot, "SAPHIR Launcher.vbs")
localApplicationLayoutPath = fso.BuildPath(bundleRoot, "scripts\lib\ApplicationLayout.ps1")
CopyLauncherFile sourceIconPath, localIconPath, "the SAPHIR icon"
CopyLauncherFile sourceLauncherHostPath, localLauncherHostPath, "the automatic launcher host"

' Keep stable pointers outside immutable bundles. The host reads these files
' and can therefore move to a new launcher bundle without changing the Desktop
' shortcut again.
On Error Resume Next
Set stableDistributionRootFile = fso.CreateTextFile(fso.BuildPath(localLauncherRoot, "distribution-root.txt"), True, True)
If Err.Number = 0 Then
    stableDistributionRootFile.WriteLine distributionRoot
    stableDistributionRootFile.Close
End If
copyError = Err.Number
copyErrorDescription = Err.Description
Err.Clear
If copyError = 0 Then
    Set pointerFile = fso.CreateTextFile(localLauncherPointerPath & ".tmp", True, True)
    If Err.Number = 0 Then
        pointerFile.WriteLine bundleId
        pointerFile.Close
        If fso.FileExists(localLauncherPointerPath) Then
            fso.DeleteFile localLauncherPointerPath, True
        End If
        fso.MoveFile localLauncherPointerPath & ".tmp", localLauncherPointerPath
    End If
    copyError = Err.Number
    copyErrorDescription = Err.Description
    Err.Clear
End If
On Error GoTo 0
If copyError <> 0 Then
    shell.Popup "SAPHIR could not activate its automatic launcher." & vbCrLf & copyErrorDescription, 0, "SAPHIR", 16
    WScript.Quit 1
End If
CopyLauncherFile sourceLauncherVersionPath, localLauncherVersionPath, "the launcher version marker"

desktopPath = shell.SpecialFolders("Desktop")
shortcutPath = fso.BuildPath(desktopPath, "SAPHIR.lnk")
Set shortcut = shell.CreateShortcut(shortcutPath)
shortcut.TargetPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wscript.exe")
shortcut.Arguments = Chr(34) & localLauncherHostPath & Chr(34)
shortcut.WorkingDirectory = localLauncherRoot
shortcut.IconLocation = localIconPath & ",0"
shortcut.Description = "SAPHIR"
shortcut.WindowStyle = 1
On Error Resume Next
shortcut.Save
copyError = Err.Number
copyErrorDescription = Err.Description
Err.Clear
On Error GoTo 0
If copyError <> 0 Then
    shell.Popup "SAPHIR could not update its Desktop shortcut." & vbCrLf & copyErrorDescription, 0, "SAPHIR", 16
    WScript.Quit 1
End If

failedReleasePath = fso.BuildPath(localRoot, "failed.json")
failedReleaseReset = False
If fso.FileExists(localApplicationLayoutPath) And fso.FileExists(failedReleasePath) Then
    If Not InvalidateFailedReleaseMarker(failedReleasePath) Then
        shell.Popup "Le nouveau lanceur SAPHIR est installe, mais la version en echec n'a pas pu etre debloquee." & vbCrLf & _
            "Fermez SAPHIR et relancez cet installateur." & vbCrLf & vbCrLf & _
            "The new launcher is installed, but the failed release could not be unlocked." & vbCrLf & copyErrorDescription, 0, "SAPHIR", 48
        WScript.Quit 1
    End If
    failedReleaseReset = True
End If

confirmationMessage = "Le lanceur SAPHIR a ete mis a niveau et son raccourci a ete actualise." & vbCrLf & _
    "Version du lanceur : " & bundleId
If failedReleaseReset Then
    confirmationMessage = confirmationMessage & vbCrLf & _
        "La version actuelle a ete debloquee et sera retentee au prochain Demarrer ou Redemarrer."
End If
confirmationMessage = confirmationMessage & vbCrLf & vbCrLf & _
    "The SAPHIR launcher was upgraded and its Desktop shortcut was refreshed."

silentInstall = False
For Each installerArgument In WScript.Arguments
    If LCase(Trim(CStr(installerArgument))) = "/silent" Then
        silentInstall = True
    End If
Next
If Not silentInstall Then
    shell.Popup confirmationMessage, 0, "SAPHIR", 64
    ' Complete the first-use path in one action. Automatic /silent launcher
    ' upgrades deliberately skip this to avoid opening a duplicate window.
    windowsScriptHost = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wscript.exe")
    If Not fso.FileExists(windowsScriptHost) Then
        windowsScriptHost = "wscript.exe"
    End If
    shell.Run Chr(34) & windowsScriptHost & Chr(34) & " " & Chr(34) & localLauncherHostPath & Chr(34), 1, False
End If
