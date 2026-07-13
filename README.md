# 闪耀星骑士通常攻击演出成人变身动画替换 MOD

本 MOD 会将《闪耀星骑士》中角色发动“通常攻击 1”和“通常攻击 2”时出现的角色演出替换为该角色的高画质成人变身动画（R18）。当前提供 PC 正式版和 Android 0.2.8 Dev 测试版。它不会改变实际攻击动作、伤害或战斗速度。

目前两种通常攻击都会生效；后续可能开发仅在“通常攻击 2”时生效的可选版本。

当前不支持露露（`[炎宿せし宝石] ルルゥ`）。PC 和 Android 版都会跳过该角色，通常攻击时继续使用游戏原始演出。

游戏动画资源不会包含在下载包中。安装工具会根据你的游戏版本获取所需资源，并尽量复用已经下载的内容。

## 选择版本

### PC 版 Release 1.2.2

适用于 Windows PC 版游戏，提供一键安装、更新和卸载。

[下载 PC 版 Release 1.2.2](https://github.com/YayiMiko/TSKSkinSwap/releases/tag/pc-v1.2.2)

1. 下载 `TskSkinSwap-PC-v1.2.2.zip` 并完整解压。
2. 如果游戏目录下没有 `mods` 文件夹，请自行新建一个。
3. 将解压出的 `TskSkinSwap` 文件夹放到 `<游戏目录>\mods\TskSkinSwap\`。
4. 完全关闭游戏，进入该 `TskSkinSwap` 文件夹，双击里面的 `Apply-TskSkinSwap.bat`。
5. 显示 `Completed successfully` 后启动游戏。

发布包已包含编译好的插件，不需要安装 .NET SDK。首次安装约需下载 1 GB 动画资源。详细说明见 [PC 版使用说明](README.pc.md)。

已经安装 PC 旧版的用户无需卸载：下载并完整解压 1.2.2，用新的 `TskSkinSwap` 文件夹覆盖原文件夹，然后在游戏关闭时再次运行 `Apply-TskSkinSwap.bat` 即可。已经下载且仍然有效的资源会继续复用。

### Android 版 Release 0.2.8

[下载 Android 版 Release 0.2.8](https://github.com/YayiMiko/TSKSkinSwap/releases/tag/android-v0.2.8)

Android 版会自动准备所需文件，保留汉化和手机上的大型游戏数据，并只补齐缺失的变身资源。已在 Android 16 真机完成通常攻击 1 和 2、连续击杀、图鉴预览后进入战斗、场景切换及完整重启测试。使用前请阅读 [Android 版说明](README.android.md)。

当前 Android 正式版仍需 Windows 电脑、数据线和 USB 调试。无需电脑、直接在安卓手机上完成安装与更新的版本正在开发中。

## 游戏更新后

先正常启动游戏一次并完成更新，然后关闭游戏，重新运行对应版本的安装 BAT。PC 版运行 `Apply-TskSkinSwap.bat`，Android 版连接并授权手机后运行 `Apply-TskSkinSwap-Android.bat`。Android 旧配置在检测到游戏更新后会自动停用；仍然有效的资源会继续复用。

## 常见问题

### 安装成功但动画没有变化

确认测试角色拥有成人变身动画，并实际触发“通常攻击 1”或“通常攻击 2”。游戏更新后请重新应用 MOD。

### 下载中断

重新运行安装 BAT。已经完成的文件会被复用，无需从头开始。

### 如何恢复原版

PC 版：完全关闭游戏后运行 `Uninstall-TskSkinSwap.bat`。选择 `Complete uninstall` 会删除 MOD、下载资源和本地工具；选择 `Disable only` 则保留资源，方便之后快速恢复。

Android 版：连接并授权手机后运行 `Uninstall-TskSkinSwap-Android.bat`。工具会覆盖恢复未内置本 MOD 的标准兼容安卓安装包，默认保留变身资源，并在完成后自动启动手机上的游戏。

## 资源说明

本仓库和 Release 不包含游戏动画或游戏安装包。请勿重新分发安装工具下载得到的游戏资源。

[English](README.en.md)
