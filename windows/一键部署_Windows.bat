@echo off
setlocal
title SrunLogin Windows Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" echo Installation ended with exit code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
