@echo off
setlocal
title Uninstall SrunLogin Windows Startup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" echo Uninstall ended with exit code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
