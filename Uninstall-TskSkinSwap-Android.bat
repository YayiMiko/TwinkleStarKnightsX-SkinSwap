@echo off
setlocal
chcp 65001 >nul

echo 正在停用闪耀星骑士 Android 动画替换 MOD...
echo 已下载的变身资源将保留，方便以后重新安装。
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-TskSkinSwap-Android.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
    echo 卸载完成，游戏已经恢复为原始动画。
) else (
    echo 卸载失败，错误代码：%EXIT_CODE%
)
echo.
pause
exit /b %EXIT_CODE%
