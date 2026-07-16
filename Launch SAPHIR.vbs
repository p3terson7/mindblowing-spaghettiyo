Dim shell
Dim fso
Dim repoRoot
Dim powerShellCommand
Dim scriptPath

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

repoRoot = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = Chr(34) & repoRoot & "\scripts\launch-cached-app.ps1" & Chr(34)

powerShellCommand = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(powerShellCommand) Then
    powerShellCommand = "powershell.exe"
End If

shell.Run Chr(34) & powerShellCommand & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -File " & scriptPath & " -Force", 0, True
