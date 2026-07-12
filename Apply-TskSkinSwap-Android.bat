@echo off
setlocal
chcp 65001 >nul

echo 闪耀星骑士 Android 通常攻击演出成人变身动画替换 MOD
echo.
echo 请连接手机，并确认已经允许 USB 调试。
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-TskSkinSwap-Android.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
    echo 安装完成，游戏已经重新启动。
) else (
    echo 安装失败，错误代码：%EXIT_CODE%
    echo 请检查上方提示后重试。
)
echo.
pause
exit /b %EXIT_CODE%
