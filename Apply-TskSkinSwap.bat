@echo off
setlocal
chcp 65001 >nul

set "TOOL_DIR=%~dp0"
for %%I in ("%TOOL_DIR%..\..") do set "GAME_DIR=%%~fI"

echo TSK Skin Swap
echo Game: %GAME_DIR%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TOOL_DIR%Update-TskSkinSwap.ps1" -GamePath "%GAME_DIR%"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
    echo Completed successfully. You can now start the game.
) else (
    echo Failed with exit code %EXIT_CODE%.
    echo Close the game, check the message above, and run this file again.
)
echo.
pause
exit /b %EXIT_CODE%
