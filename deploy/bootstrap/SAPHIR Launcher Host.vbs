Option Explicit

Dim shell
Dim fso
Dim localAppData
Dim localRoot
Dim launcherRoot
Dim versionsRoot
Dim distributionRootPath
Dim distributionRoot
Dim localVersionPath
Dim sharedVersionPath
Dim localVersion
Dim sharedVersion
Dim sharedInstallerPath
Dim pointerPath
Dim bundleId
Dim bundleRoot
Dim launcherEntryPath
Dim windowsScriptHost
Dim installExitCode
Dim updateCheckOnly
Dim updateLockPath
Dim updateLockFile
Dim updateLockAcquired
Dim launcherArgument

Function IsSafeBundleId(value)
    Dim position
    Dim currentCharacter

    IsSafeBundleId = False
    If Len(value) = 0 Or Len(value) > 96 Then
        Exit Function
    End If

    For position = 1 To Len(value)
        currentCharacter = Mid(value, position, 1)
        If InStr("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_", currentCharacter) = 0 Then
            Exit Function
        End If
    Next

    IsSafeBundleId = True
End Function

Function ReadTextFile(filePath, unicodeText)
    Dim stream
    ReadTextFile = ""
    If Not fso.FileExists(filePath) Then
        Exit Function
    End If

    On Error Resume Next
    If unicodeText Then
        Set stream = fso.OpenTextFile(filePath, 1, False, -1)
    Else
        Set stream = fso.OpenTextFile(filePath, 1, False, -2)
    End If
    If Err.Number = 0 Then
        ReadTextFile = Trim(stream.ReadAll)
        stream.Close
    End If
    Err.Clear
    On Error GoTo 0
End Function

Function FindNewestLauncherBundle(rootPath)
    Dim versionsFolder
    Dim childFolder
    Dim selectedFolder

    FindNewestLauncherBundle = ""
    If Not fso.FolderExists(rootPath) Then
        Exit Function
    End If

    Set versionsFolder = fso.GetFolder(rootPath)
    Set selectedFolder = Nothing
    For Each childFolder In versionsFolder.SubFolders
        If Left(childFolder.Name, 1) <> "." And IsSafeBundleId(childFolder.Name) Then
            If selectedFolder Is Nothing Then
                Set selectedFolder = childFolder
            ElseIf childFolder.DateLastModified > selectedFolder.DateLastModified Then
                Set selectedFolder = childFolder
            End If
        End If
    Next

    If Not selectedFolder Is Nothing Then
        FindNewestLauncherBundle = selectedFolder.Name
    End If
End Function

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
launcherEntryPath = ""
updateCheckOnly = False
For Each launcherArgument In WScript.Arguments
    If LCase(Trim(CStr(launcherArgument))) = "/check-update" Then
        updateCheckOnly = True
    End If
Next

localAppData = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%")
If Len(localAppData) = 0 Or InStr(localAppData, "%") > 0 Then
    localAppData = shell.ExpandEnvironmentStrings("%TEMP%")
End If
If Len(localAppData) = 0 Or InStr(localAppData, "%") > 0 Then
    shell.Popup "SAPHIR ne peut pas trouver son dossier local.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

localRoot = fso.BuildPath(localAppData, "SAPHIR")
launcherRoot = fso.BuildPath(localRoot, "launcher")
versionsRoot = fso.BuildPath(launcherRoot, "versions")
distributionRootPath = fso.BuildPath(launcherRoot, "distribution-root.txt")
distributionRoot = ReadTextFile(distributionRootPath, True)
localVersionPath = fso.BuildPath(launcherRoot, "launcher-version.txt")
localVersion = ReadTextFile(localVersionPath, False)

' The host is deliberately tiny and stable. When the distribution is
' reachable, a hidden background copy lets the signed-off installer replace
' the complete launcher bundle atomically. The normal path opens the graphical
' window first, so an unavailable network share can never delay the employee.
If updateCheckOnly Then
    updateLockPath = fso.BuildPath(launcherRoot, ".update-check.lock")
    updateLockAcquired = False
    If fso.FileExists(updateLockPath) Then
        On Error Resume Next
        If DateDiff("n", fso.GetFile(updateLockPath).DateLastModified, Now) >= 15 Then
            fso.DeleteFile updateLockPath, True
        End If
        Err.Clear
        On Error GoTo 0
    End If
    On Error Resume Next
    Set updateLockFile = fso.CreateTextFile(updateLockPath, False, False)
    If Err.Number = 0 Then
        updateLockFile.WriteLine CStr(Now)
        updateLockFile.Close
        updateLockAcquired = True
    End If
    Err.Clear
    On Error GoTo 0
    If Not updateLockAcquired Then
        WScript.Quit 0
    End If

    If Len(distributionRoot) > 0 Then
        sharedVersionPath = fso.BuildPath(distributionRoot, "launcher-version.txt")
        sharedVersion = ReadTextFile(sharedVersionPath, False)
        If Len(sharedVersion) > 0 And StrComp(sharedVersion, localVersion, vbTextCompare) <> 0 Then
            sharedInstallerPath = fso.BuildPath(distributionRoot, "Install SAPHIR Shortcut.vbs")
            If fso.FileExists(sharedInstallerPath) Then
                windowsScriptHost = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wscript.exe")
                If Not fso.FileExists(windowsScriptHost) Then
                    windowsScriptHost = "wscript.exe"
                End If
                On Error Resume Next
                installExitCode = shell.Run(Chr(34) & windowsScriptHost & Chr(34) & " " & _
                    Chr(34) & sharedInstallerPath & Chr(34) & " /silent", 0, True)
                Err.Clear
                On Error GoTo 0
            End If
        End If
    End If

    On Error Resume Next
    If fso.FileExists(updateLockPath) Then
        fso.DeleteFile updateLockPath, True
    End If
    On Error GoTo 0
    WScript.Quit 0
End If

pointerPath = fso.BuildPath(launcherRoot, "current.txt")
bundleId = ReadTextFile(pointerPath, True)
If Not IsSafeBundleId(bundleId) Then
    bundleId = ""
End If
If Len(bundleId) = 0 Then
    bundleId = FindNewestLauncherBundle(versionsRoot)
End If

If Len(bundleId) > 0 Then
    bundleRoot = fso.BuildPath(versionsRoot, bundleId)
    launcherEntryPath = fso.BuildPath(bundleRoot, "SAPHIR Launcher.vbs")
End If

If Len(bundleId) = 0 Or Not fso.FileExists(launcherEntryPath) Then
    shell.Popup "Le lanceur SAPHIR local est incomplet. Relancez Install SAPHIR Shortcut.vbs une fois depuis le dossier partagé.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

windowsScriptHost = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wscript.exe")
If Not fso.FileExists(windowsScriptHost) Then
    windowsScriptHost = "wscript.exe"
End If
shell.Run Chr(34) & windowsScriptHost & Chr(34) & " " & Chr(34) & launcherEntryPath & Chr(34), 1, False
' Network access happens only in this detached helper. The graphical launcher
' has already been requested and therefore remains fast even when SMB is down.
shell.Run Chr(34) & windowsScriptHost & Chr(34) & " " & Chr(34) & WScript.ScriptFullName & Chr(34) & " /check-update", 0, False
