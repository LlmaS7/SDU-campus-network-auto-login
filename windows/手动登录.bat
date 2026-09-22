@echo off
setlocal
set "SRUN_SCRIPT=%ProgramData%\SrunLogin\srun_login.ps1"
if not exist "%SRUN_SCRIPT%" (
    echo SrunLogin is not installed. Run one-click Windows deployment first.
    echo.
    pause
    exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SRUN_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo SrunLogin exit code: %EXIT_CODE%
pause
exit /b %EXIT_CODE%
