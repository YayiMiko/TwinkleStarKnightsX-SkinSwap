@echo off
setlocal EnableExtensions

echo TSK Skin Swap - Android installer
echo.
echo Connect the phone and allow USB debugging when prompted.
echo.

if not exist "%~dp0Apply-TskSkinSwap-Android.ps1" goto missing_files

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-TskSkinSwap-Android.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="10" goto game_data_update
if not "%EXIT_CODE%"=="0" goto failed
echo Installation completed. The game has been restarted.
goto finished

:game_data_update
set "EXIT_CODE=0"
echo Compatible app update completed. The game has been started on the phone.
echo Finish the additional in-game data update, then close the game and run this BAT again.
goto finished

:failed
echo Installation failed with exit code %EXIT_CODE%.
echo Check the message above and run this file again.
goto finished

:missing_files
set "EXIT_CODE=2"
echo Required files are missing.
echo Extract the entire release ZIP to a normal folder, then run this BAT again.

:finished
call :stop_bundled_adb
echo.
pause
exit /b %EXIT_CODE%

:stop_bundled_adb
if exist "%~dp0.tools\android-installer\platform-tools\adb.exe" "%~dp0.tools\android-installer\platform-tools\adb.exe" kill-server >nul 2>&1
if exist "%~dp0.tools\android\platform-tools\adb.exe" "%~dp0.tools\android\platform-tools\adb.exe" kill-server >nul 2>&1
exit /b 0
