# 闪耀星骑士 Android 动画替换 MOD

这是 Android 版 Release 0.1。安装后，支持角色的“通常攻击 2”会替换为该角色的高画质成人变身动画（R18），战斗和非战斗动画预览均支持。

## 使用条件

- Windows 电脑和 USB 数据线。
- 手机已开启 USB 调试并允许当前电脑连接，无需 Root。
- 已安装兼容的 Mod APK，包名为 `jp.co.fanzagames.twinklestarknightsx_a_mod`。
- 首次安装需要联网。实际下载量取决于手机已有缓存；2026 年 7 月测试约需 0.66 GiB。

## 安装

1. 解压整个 Release ZIP，不要只单独取出 BAT 文件。
2. 连接手机并保持解锁，确认 USB 调试授权提示。
3. 双击 `Apply-TskSkinSwap-Android.bat`。
4. 等待窗口显示安装完成。工具会自动重启游戏。

安装器只读取当前资源目录，优先直接复用手机 UnityCache，仅从游戏官方 CDN 下载缺失的变身 Bundle。它不会复制手机上已有的数 GB 游戏数据，也不会修改游戏原始 Bundle。

## 游戏更新后

先正常启动游戏一次，让客户端完成资源更新，再重新双击安装 BAT。仍然有效的缓存和 MOD 资源会直接复用，只补充发生变化的文件。

## 卸载

双击 `Uninstall-TskSkinSwap-Android.bat`。默认保留已下载资源，便于以后重新安装。

若确定要同时释放手机空间，可连接手机后在 PowerShell 中运行：

```powershell
.\Uninstall-TskSkinSwap-Android.ps1 -RemoveBundles
```

## 常见问题

### 找不到设备

确认 USB 调试已开启、手机保持解锁，并在手机上允许这台电脑进行调试。更换 USB 连接模式或数据线后重试。

### 提示 APK 不兼容

当前版本不会自动修改原版 APK，需要先安装兼容 Mod APK。

### 下载中断

重新运行 BAT。未完成文件会断点续传，已经验证并推送的文件不会重复下载。

## 资源说明

Release 不包含 APK、游戏动画、Catalog、用户数据或已生成映射。游戏资源仅根据用户当前客户端 Catalog 从官方 CDN 下载并保存在用户自己的电脑和手机上，请勿重新分发。
