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
Dim exitCode

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

exitCode = shell.Run(Chr(34) & powerShellCommand & Chr(34) & powerShellArguments, 0, True)
If exitCode <> 0 Then
    shell.Popup "Le lanceur SAPHIR n'a pas pu s'ouvrir." & vbCrLf & "The SAPHIR launcher could not open.", 0, "SAPHIR", 16
End If

WScript.Quit exitCode
