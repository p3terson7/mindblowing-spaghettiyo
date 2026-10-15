@echo off
setlocal
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL_EXE%" set "POWERSHELL_EXE=powershell.exe"
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0scripts\start-performance-capture.ps1" -Level detailed
if errorlevel 1 (
    pause
    exit /b 1
)
echo.
echo Sign in and reproduce the slow loading, then click Export performance trace.
echo Backend traces: %LOCALAPPDATA%\SAPHIR\diagnostics\performance
pause
