@echo off
setlocal
title Verify SrunLogin Windows Startup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_setup.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXIT_CODE%
