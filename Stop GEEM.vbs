Dim shell
Dim fso
Dim repoRoot
Dim powerShellCommand
Dim scriptPath
Dim detectionCode
Dim exitCode

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

repoRoot = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = Chr(34) & repoRoot & "\scripts\stop-all.ps1" & Chr(34)

detectionCode = shell.Run("cmd /c where pwsh >nul 2>nul", 0, True)
If detectionCode = 0 Then
    powerShellCommand = "pwsh"
Else
    powerShellCommand = "powershell"
End If

exitCode = shell.Run(powerShellCommand & " -NoProfile -ExecutionPolicy Bypass -File " & scriptPath, 0, True)
If exitCode <> 0 Then
    shell.Popup "GEEM could not be stopped automatically. Run Stop GEEM.bat to see the error details.", 0, "GEEM stop failed", 48
End If
