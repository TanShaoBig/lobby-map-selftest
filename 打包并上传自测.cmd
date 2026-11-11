@echo off
setlocal
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Upload-LobbySelfTest.ps1" %*
set "UPLOAD_EXIT=%ERRORLEVEL%"
echo.
if "%UPLOAD_EXIT%"=="0" (echo Task completed.) else (echo Task stopped. Please read the result above.)
echo Press any key to close this window.
pause >nul
exit /b %UPLOAD_EXIT%
