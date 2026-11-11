@echo off
setlocal
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Upload-LobbySelfTest.ps1" -StatusOnly %*
set "QUERY_EXIT=%ERRORLEVEL%"
echo.
echo Press any key to close this window.
pause >nul
exit /b %QUERY_EXIT%
