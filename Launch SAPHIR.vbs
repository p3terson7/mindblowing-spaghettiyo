Dim shell
Dim fso
Dim repoRoot
Dim powerShellCommand
Dim scriptPath
Dim warmRequest
Dim warmStatus
Dim warmIdentity
Dim warmInstanceToken
Dim responseInstanceToken
Dim localAppData
Dim localRoot
Dim runtimeRoot
Dim pidFilePath
Dim pidFileStream
Dim pidFileText
Dim tokenPattern
Dim tokenMatches
Dim activeFilePath
Dim activeFileStream
Dim activeFileText
Dim releasePattern
Dim releaseMatches
Dim activeReleaseId
Dim serverPathPattern
Dim serverPathMatches
Dim metadataServerPath
Dim expectedServerPath
Dim warmReleaseMatches

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' The primary shortcut reaches this tiny file on the shared drive. A verified
' local SAPHIR response can reopen immediately without starting PowerShell,
' reading the release manifest, or touching the running backend.
warmStatus = 0
warmIdentity = ""
warmInstanceToken = ""
responseInstanceToken = ""
activeReleaseId = ""
metadataServerPath = ""
expectedServerPath = ""
warmReleaseMatches = False
On Error Resume Next
localAppData = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%")
If Len(localAppData) = 0 Or InStr(localAppData, "%") > 0 Then
    localAppData = shell.ExpandEnvironmentStrings("%TEMP%")
End If
localRoot = shell.ExpandEnvironmentStrings("%SAPHIR_APP_CACHE_ROOT%")
If Len(localRoot) = 0 Or InStr(localRoot, "%") > 0 Then
    localRoot = fso.BuildPath(localAppData, "SAPHIR")
End If
runtimeRoot = shell.ExpandEnvironmentStrings("%SAPHIR_RUNTIME_ROOT%")
If Len(runtimeRoot) = 0 Or InStr(runtimeRoot, "%") > 0 Then
    runtimeRoot = fso.BuildPath(localAppData, "SAPHIR\runtime")
End If
pidFilePath = fso.BuildPath(runtimeRoot, "pids\app.pid.json")
activeFilePath = fso.BuildPath(localRoot, "active.json")

If fso.FileExists(activeFilePath) Then
    Set activeFileStream = fso.OpenTextFile(activeFilePath, 1, False)
    activeFileText = activeFileStream.ReadAll
    activeFileStream.Close
    Set releasePattern = New RegExp
    releasePattern.Pattern = """releaseId""\s*:\s*""([A-Za-z0-9._-]+)"""
    releasePattern.Global = False
    releasePattern.IgnoreCase = False
    Set releaseMatches = releasePattern.Execute(activeFileText)
    If releaseMatches.Count = 1 Then
        activeReleaseId = releaseMatches(0).SubMatches(0)
    End If
End If

If fso.FileExists(pidFilePath) Then
    Set pidFileStream = fso.OpenTextFile(pidFilePath, 1, False)
    pidFileText = pidFileStream.ReadAll
    pidFileStream.Close
    Set tokenPattern = New RegExp
    tokenPattern.Pattern = """instanceToken""\s*:\s*""([0-9a-fA-F]{32})"""
    tokenPattern.Global = False
    tokenPattern.IgnoreCase = False
    Set tokenMatches = tokenPattern.Execute(pidFileText)
    If tokenMatches.Count = 1 Then
        warmInstanceToken = tokenMatches(0).SubMatches(0)
    End If
    Set serverPathPattern = New RegExp
    serverPathPattern.Pattern = """scriptPath""\s*:\s*""([^""]+)"""
    serverPathPattern.Global = False
    serverPathPattern.IgnoreCase = False
    Set serverPathMatches = serverPathPattern.Execute(pidFileText)
    If serverPathMatches.Count = 1 Then
        metadataServerPath = Replace(serverPathMatches(0).SubMatches(0), "\\", "\")
        metadataServerPath = Replace(metadataServerPath, "\/", "/")
    End If
End If

If Len(activeReleaseId) > 0 And Len(metadataServerPath) > 0 Then
    expectedServerPath = fso.BuildPath(fso.BuildPath(fso.BuildPath(localRoot, "versions"), activeReleaseId), "apps\admin\backend\admin-server.ps1")
    expectedServerPath = fso.GetAbsolutePathName(expectedServerPath)
    metadataServerPath = fso.GetAbsolutePathName(metadataServerPath)
    warmReleaseMatches = (StrComp(expectedServerPath, metadataServerPath, vbTextCompare) = 0)
End If

If Len(warmInstanceToken) = 32 And warmReleaseMatches Then
    Set warmRequest = CreateObject("WinHttp.WinHttpRequest.5.1")
    warmRequest.SetTimeouts 300, 300, 300, 900
    warmRequest.Open "GET", "http://localhost:8081/", False
    warmRequest.Send
    If Err.Number = 0 Then
        warmStatus = warmRequest.Status
        warmIdentity = warmRequest.GetResponseHeader("X-SAPHIR-App")
        responseInstanceToken = warmRequest.GetResponseHeader("X-SAPHIR-Instance")
    End If
End If
Err.Clear
On Error GoTo 0

If warmStatus >= 200 And warmStatus < 400 And warmIdentity = "SAPHIR" And responseInstanceToken = warmInstanceToken And warmReleaseMatches Then
    shell.Run "http://localhost:8081/", 1, False
    WScript.Quit 0
End If

repoRoot = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = Chr(34) & repoRoot & "\scripts\launch-cached-app.ps1" & Chr(34)

powerShellCommand = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powerShellCommand) Then
    powerShellCommand = "powershell.exe"
End If

shell.Run Chr(34) & powerShellCommand & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -File " & scriptPath, 0, True
