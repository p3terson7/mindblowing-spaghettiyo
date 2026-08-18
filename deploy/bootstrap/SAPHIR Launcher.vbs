Option Explicit

Dim shell
Dim fso
Dim launcherRoot
Dim launcherScript
Dim distributionRoot
Dim distributionRootFilePath
Dim distributionRootFile
Dim powerShellCommand
Dim powerShellArguments
Dim commandProcessor
Dim launchCommand
Dim localAppData
Dim diagnosticRoot
Dim launcherLogPath
Dim diagnosticFile
Dim errorDetails
Dim launchErrorDescription
Dim validationMode
Dim failureMessage
Dim exitCode

Sub EnsureDiagnosticFolder(folderPath)
    Dim parentPath

    If Len(folderPath) = 0 Or fso.FolderExists(folderPath) Then
        Exit Sub
    End If

    parentPath = fso.GetParentFolderName(folderPath)
    If Len(parentPath) > 0 And Not fso.FolderExists(parentPath) Then
        EnsureDiagnosticFolder parentPath
    End If

    On Error Resume Next
    fso.CreateFolder folderPath
    Err.Clear
    On Error GoTo 0
End Sub

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

launcherRoot = fso.GetAbsolutePathName(fso.GetParentFolderName(WScript.ScriptFullName))
launcherScript = fso.BuildPath(launcherRoot, "scripts\saphir-launcher.ps1")
distributionRoot = launcherRoot
distributionRootFilePath = fso.BuildPath(launcherRoot, "distribution-root.txt")

' The installed AppData copy remembers the canonical distribution but never
' probes it here. The WPF window opens immediately and performs network checks
' on a background runspace, so an unavailable share cannot freeze startup.
If fso.FileExists(distributionRootFilePath) Then
    On Error Resume Next
    Set distributionRootFile = fso.OpenTextFile(distributionRootFilePath, 1, False, -1)
    If Err.Number = 0 Then
        distributionRoot = Trim(distributionRootFile.ReadAll)
        distributionRootFile.Close
    End If
    Err.Clear
    On Error GoTo 0

End If

If Not fso.FileExists(launcherScript) Then
    shell.Popup "Le lanceur SAPHIR est incomplet." & vbCrLf & "The SAPHIR launcher is incomplete.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

powerShellCommand = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powerShellCommand) Then
    powerShellCommand = "powershell.exe"
End If

powerShellArguments = " -NoProfile -STA -ExecutionPolicy Bypass -File " & Chr(34) & launcherScript & Chr(34)
If Len(distributionRoot) > 0 Then
    powerShellArguments = powerShellArguments & " -DistributionRoot " & Chr(34) & distributionRoot & Chr(34)
End If
validationMode = (shell.ExpandEnvironmentStrings("%SAPHIR_LAUNCHER_VALIDATE_ONLY%") = "1")
If validationMode Then
    powerShellArguments = powerShellArguments & " -ValidateOnly"
End If

localAppData = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%")
If Len(localAppData) = 0 Or InStr(localAppData, "%") > 0 Then
    localAppData = shell.ExpandEnvironmentStrings("%TEMP%")
End If
diagnosticRoot = fso.BuildPath(fso.BuildPath(fso.BuildPath(localAppData, "SAPHIR"), "runtime"), "logs")
EnsureDiagnosticFolder diagnosticRoot
If fso.FolderExists(diagnosticRoot) Then
    launcherLogPath = fso.BuildPath(diagnosticRoot, "launcher-startup.log")
Else
    launcherLogPath = fso.BuildPath(shell.ExpandEnvironmentStrings("%TEMP%"), "SAPHIR-launcher-startup.log")
End If

' Run through cmd only to capture startup and parser errors from the otherwise
' hidden PowerShell process. The WPF window itself still opens without a console.
commandProcessor = shell.ExpandEnvironmentStrings("%ComSpec%")
If Len(commandProcessor) = 0 Or InStr(commandProcessor, "%") > 0 Then
    commandProcessor = "cmd.exe"
End If
launchCommand = Chr(34) & commandProcessor & Chr(34) & " /d /s /c " & _
    Chr(34) & Chr(34) & powerShellCommand & Chr(34) & powerShellArguments & _
    " > " & Chr(34) & launcherLogPath & Chr(34) & " 2>&1" & Chr(34)

launchErrorDescription = ""
On Error Resume Next
exitCode = shell.Run(launchCommand, 0, True)
If Err.Number <> 0 Then
    launchErrorDescription = Err.Description
    exitCode = 1
End If
Err.Clear
On Error GoTo 0

If exitCode <> 0 Then
    errorDetails = ""
    If fso.FileExists(launcherLogPath) Then
        On Error Resume Next
        Set diagnosticFile = fso.OpenTextFile(launcherLogPath, 1, False, -2)
        If Err.Number = 0 Then
            errorDetails = Trim(diagnosticFile.ReadAll)
            diagnosticFile.Close
        End If
        Err.Clear
        On Error GoTo 0
    End If
    If Len(errorDetails) = 0 Then
        errorDetails = launchErrorDescription
    End If
    If Len(errorDetails) > 1400 Then
        errorDetails = "..." & Right(errorDetails, 1397)
    End If

    failureMessage = "Le lanceur SAPHIR n'a pas pu s'ouvrir." & vbCrLf & _
        "The SAPHIR launcher could not open." & vbCrLf & vbCrLf & _
        errorDetails & vbCrLf & vbCrLf & _
        "Journal / Log: " & launcherLogPath
    If validationMode Then
        WScript.Echo failureMessage
    Else
        shell.Popup failureMessage, 0, "SAPHIR", 16
    End If
End If

WScript.Quit exitCode
