@echo off
setlocal
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL_EXE%" set "POWERSHELL_EXE=powershell.exe"
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0scripts\benchmark-live-app.ps1"
if errorlevel 1 (
    pause
    exit /b 1
)
echo.
echo The benchmark report ZIP path is printed above.
pause
