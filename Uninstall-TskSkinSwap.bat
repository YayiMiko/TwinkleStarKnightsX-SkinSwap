@echo off
setlocal
chcp 65001 >nul

set "TOOL_DIR=%~dp0"
for %%I in ("%TOOL_DIR%..\..") do set "GAME_DIR=%%~fI"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TOOL_DIR%Uninstall-TskSkinSwap.ps1" -GamePath "%GAME_DIR%"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXIT_CODE%
