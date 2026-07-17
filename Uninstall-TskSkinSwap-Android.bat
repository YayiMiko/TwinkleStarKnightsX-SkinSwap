@echo off
setlocal EnableExtensions

echo TSK Skin Swap - Android uninstaller
echo Downloaded transform bundles will be kept for reuse.
echo.

if not exist "%~dp0Uninstall-TskSkinSwap-Android.ps1" goto missing_files

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-TskSkinSwap-Android.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" goto failed
echo Uninstall completed. The compatible Android package and original animations are active again.
goto finished

:failed
echo Uninstall failed with exit code %EXIT_CODE%.
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
if exist "%TEMP%\TskSkinSwap\android-platform-tools\platform-tools\adb.exe" "%TEMP%\TskSkinSwap\android-platform-tools\platform-tools\adb.exe" kill-server >nul 2>&1
if exist "%~dp0.tools\android-installer\platform-tools\adb.exe" "%~dp0.tools\android-installer\platform-tools\adb.exe" kill-server >nul 2>&1
if exist "%~dp0.tools\android\platform-tools\adb.exe" "%~dp0.tools\android\platform-tools\adb.exe" kill-server >nul 2>&1
exit /b 0
