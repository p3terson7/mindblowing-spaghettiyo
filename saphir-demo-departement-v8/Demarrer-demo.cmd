@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Start-demo.ps1" %*
if errorlevel 1 pause
