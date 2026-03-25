Dim shell
Dim fso
Dim repoRoot
Dim powerShellCommand
Dim scriptPath
Dim detectionCode

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

repoRoot = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = Chr(34) & repoRoot & "\scripts\launch-app.ps1" & Chr(34)

detectionCode = shell.Run("cmd /c where pwsh >nul 2>nul", 0, True)
If detectionCode = 0 Then
    powerShellCommand = "pwsh"
Else
    powerShellCommand = "powershell"
End If

shell.Run powerShellCommand & " -NoProfile -ExecutionPolicy Bypass -File " & scriptPath, 0, False
