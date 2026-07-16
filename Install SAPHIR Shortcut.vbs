Option Explicit

Dim shell
Dim fso
Dim distributionRoot
Dim launchScriptPath
Dim sourceIconPath
Dim localAppData
Dim localRoot
Dim localAssetsRoot
Dim localIconPath
Dim desktopPath
Dim shortcutPath
Dim shortcut
Dim copyError

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

distributionRoot = fso.GetParentFolderName(WScript.ScriptFullName)
launchScriptPath = fso.BuildPath(distributionRoot, "Launch SAPHIR.vbs")
sourceIconPath = fso.BuildPath(distributionRoot, "SAPHIR.ico")

If Not fso.FileExists(launchScriptPath) Then
    shell.Popup "Launch SAPHIR.vbs is missing from the distribution folder.", 0, "SAPHIR", 16
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

localRoot = fso.BuildPath(localAppData, "SAPHIR")
localAssetsRoot = fso.BuildPath(localRoot, "assets")
If Not fso.FolderExists(localRoot) Then
    fso.CreateFolder localRoot
End If
If Not fso.FolderExists(localAssetsRoot) Then
    fso.CreateFolder localAssetsRoot
End If

localIconPath = fso.BuildPath(localAssetsRoot, "SAPHIR.ico")
On Error Resume Next
fso.CopyFile sourceIconPath, localIconPath, True
copyError = Err.Number
Err.Clear
On Error GoTo 0
If copyError <> 0 Then
    shell.Popup "The SAPHIR icon could not be copied to local AppData.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

desktopPath = shell.SpecialFolders("Desktop")
shortcutPath = fso.BuildPath(desktopPath, "SAPHIR.lnk")
Set shortcut = shell.CreateShortcut(shortcutPath)
shortcut.TargetPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wscript.exe")
shortcut.Arguments = Chr(34) & launchScriptPath & Chr(34)
shortcut.WorkingDirectory = distributionRoot
shortcut.IconLocation = localIconPath & ",0"
shortcut.Description = "SAPHIR"
shortcut.WindowStyle = 1
shortcut.Save

shell.Popup "Le raccourci SAPHIR a ete cree sur le Bureau." & vbCrLf & "The SAPHIR shortcut was created on the Desktop.", 0, "SAPHIR", 64
