Dim shell
Dim fso
Dim repoRoot
Dim powerShellCommand
Dim scriptPath
Dim exitCode

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

repoRoot = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = Chr(34) & repoRoot & "\scripts\stop-all.ps1" & Chr(34)

powerShellCommand = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powerShellCommand) Then
    powerShellCommand = "powershell.exe"
End If

exitCode = shell.Run(Chr(34) & powerShellCommand & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -File " & scriptPath, 0, True)
If exitCode <> 0 Then
    shell.Popup "SAPHIR could not be stopped automatically. Run Stop SAPHIR.bat to see the error details.", 0, "SAPHIR stop failed", 48
End If
