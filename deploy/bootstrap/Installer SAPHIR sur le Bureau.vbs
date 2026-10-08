Option Explicit

Dim shell
Dim fso
Dim distributionRoot
Dim installerPath
Dim windowsScriptHost
Dim command
Dim argument
Dim exitCode

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

distributionRoot = fso.GetAbsolutePathName(fso.GetParentFolderName(WScript.ScriptFullName))
installerPath = fso.BuildPath(distributionRoot, "Install SAPHIR Shortcut.vbs")

If Not fso.FileExists(installerPath) Then
    shell.Popup "L'installateur SAPHIR principal est introuvable dans ce dossier." & vbCrLf & vbCrLf & _
        "The main SAPHIR installer is missing from this folder.", 0, "SAPHIR", 16
    WScript.Quit 1
End If

windowsScriptHost = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\wscript.exe")
If Not fso.FileExists(windowsScriptHost) Then
    windowsScriptHost = "wscript.exe"
End If

command = Chr(34) & windowsScriptHost & Chr(34) & " " & Chr(34) & installerPath & Chr(34)
For Each argument In WScript.Arguments
    command = command & " " & Chr(34) & Replace(CStr(argument), Chr(34), "") & Chr(34)
Next

exitCode = shell.Run(command, 1, True)
WScript.Quit exitCode
