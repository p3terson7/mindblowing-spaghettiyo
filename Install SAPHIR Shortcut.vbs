Option Explicit

Dim shell
Dim fso
Dim distributionRoot
Dim sourceLauncherEntryPath
Dim sourceLauncherScriptPath
Dim sourceLauncherControlPath
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
Dim bundleRoot
Dim localLauncherEntryPath
Dim localBundleIconPath
Dim localLauncherScriptPath
Dim localLauncherControlPath
Dim localCachedLaunchPath
Dim localLocalCachePath
Dim localServerControlPath
Dim distributionRootFilePath
Dim distributionRootFile
Dim desktopPath
Dim shortcutPath
Dim shortcut
Dim copyError
Dim copyErrorDescription

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
sourceLauncherScriptPath = fso.BuildPath(distributionRoot, "scripts\saphir-launcher.ps1")
sourceLauncherControlPath = fso.BuildPath(distributionRoot, "scripts\lib\LauncherControl.ps1")
sourceCachedLaunchPath = fso.BuildPath(distributionRoot, "scripts\launch-cached-app.ps1")
sourceLocalCachePath = fso.BuildPath(distributionRoot, "scripts\lib\LocalAppCache.ps1")
sourceServerControlPath = fso.BuildPath(distributionRoot, "scripts\lib\ServerControl.ps1")
sourceIconPath = fso.BuildPath(distributionRoot, "SAPHIR.ico")

If Not fso.FileExists(sourceLauncherEntryPath) Then
    shell.Popup "SAPHIR Launcher.vbs is missing from the distribution folder.", 0, "SAPHIR", 16
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

EnsureFolder localRoot
EnsureFolder localAssetsRoot
EnsureFolder localLauncherRoot
EnsureFolder localLauncherVersionsRoot

localIconPath = fso.BuildPath(localAssetsRoot, "SAPHIR.ico")
Randomize
bundleId = CStr(Year(Now)) & Right("0" & CStr(Month(Now)), 2) & Right("0" & CStr(Day(Now)), 2) & "-" & _
    Right("0" & CStr(Hour(Now)), 2) & Right("0" & CStr(Minute(Now)), 2) & Right("0" & CStr(Second(Now)), 2) & "-" & _
    Right("000000" & Hex(Int(Rnd * 16777215)), 6)
stagingRoot = fso.BuildPath(localLauncherRoot, ".staging-" & bundleId)
stagingScriptsRoot = fso.BuildPath(stagingRoot, "scripts")
stagingLibraryRoot = fso.BuildPath(stagingScriptsRoot, "lib")
bundleRoot = fso.BuildPath(localLauncherVersionsRoot, bundleId)

EnsureFolder stagingRoot
EnsureFolder stagingScriptsRoot
EnsureFolder stagingLibraryRoot

localLauncherEntryPath = fso.BuildPath(stagingRoot, "SAPHIR Launcher.vbs")
localBundleIconPath = fso.BuildPath(stagingRoot, "SAPHIR.ico")
localLauncherScriptPath = fso.BuildPath(stagingScriptsRoot, "saphir-launcher.ps1")
localLauncherControlPath = fso.BuildPath(stagingLibraryRoot, "LauncherControl.ps1")
localCachedLaunchPath = fso.BuildPath(stagingScriptsRoot, "launch-cached-app.ps1")
localLocalCachePath = fso.BuildPath(stagingLibraryRoot, "LocalAppCache.ps1")
localServerControlPath = fso.BuildPath(stagingLibraryRoot, "ServerControl.ps1")
distributionRootFilePath = fso.BuildPath(stagingRoot, "distribution-root.txt")

CopyLauncherFile sourceLauncherScriptPath, localLauncherScriptPath, "the launcher interface"
CopyLauncherFile sourceLauncherControlPath, localLauncherControlPath, "the launcher controller"
CopyLauncherFile sourceCachedLaunchPath, localCachedLaunchPath, "the cached application starter"
CopyLauncherFile sourceLocalCachePath, localLocalCachePath, "the local application cache support"
CopyLauncherFile sourceServerControlPath, localServerControlPath, "the local service controller"
CopyLauncherFile sourceIconPath, localBundleIconPath, "the launcher icon"
CopyLauncherFile sourceLauncherEntryPath, localLauncherEntryPath, "the launcher"

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
   Not fso.FileExists(localCachedLaunchPath) Or _
   Not fso.FileExists(localLocalCachePath) Or _
   Not fso.FileExists(localServerControlPath) Or _
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
CopyLauncherFile sourceIconPath, localIconPath, "the SAPHIR icon"

desktopPath = shell.SpecialFolders("Desktop")
shortcutPath = fso.BuildPath(desktopPath, "SAPHIR.lnk")
Set shortcut = shell.CreateShortcut(shortcutPath)
shortcut.TargetPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wscript.exe")
shortcut.Arguments = Chr(34) & localLauncherEntryPath & Chr(34)
shortcut.WorkingDirectory = bundleRoot
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

shell.Popup "Le lanceur SAPHIR a ete installe et son raccourci a ete cree sur le Bureau." & vbCrLf & "The SAPHIR launcher and desktop shortcut were installed.", 0, "SAPHIR", 64
