@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Pack-LobbyMap.ps1" %*
set "PACK_EXIT=%ERRORLEVEL%"

echo.
if "%PACK_EXIT%"=="0" (
    echo Packaging succeeded.
) else (
    echo Packaging failed with exit code %PACK_EXIT%.
)
echo Press any key to close this window.
pause >nul

exit /b %PACK_EXIT%
