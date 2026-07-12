# TskSkinSwap

这是一个适用于 PC 版《闪耀星骑士》的 R18 动画替换 MOD。

安装后，MOD 会将《闪耀星骑士》中角色的“通常攻击 2”动画替换为该角色的高画质变身动画（R18）。支持的角色会自动匹配，无需在游戏中逐个打开变身界面下载资源。

[English](README.en.md)

## 使用前准备

- 仅支持 Windows PC 版游戏。
- 首次安装需要联网，并预留至少 2.1 GB 磁盘空间。
- 操作前必须完全关闭游戏。
- 游戏更新后，需要先正常启动并进入一次游戏，让客户端更新资源目录，然后再关闭游戏运行本工具。

## 安装方法

1. 打开 [Releases](https://github.com/YayiMiko/TwinkleStarKnightsX-SkinSwap/releases)，下载最新的 `TskSkinSwap-版本号.zip`。
2. 解压后，将整个 `TskSkinSwap` 文件夹放入游戏目录下的 `mods` 文件夹：

   ```text
   <游戏目录>\mods\TskSkinSwap\
   ```

3. 双击 `Apply-TskSkinSwap.bat`。
4. 首次运行会自动下载运行组件和角色动画资源，请耐心等待。
5. 窗口显示 `Completed successfully` 后，关闭窗口并启动游戏。

以后正常启动游戏即可，不需要每次运行安装脚本。

## 游戏更新后

1. 正常启动一次游戏，等待客户端完成更新，然后关闭游戏。
2. 再次双击 `Apply-TskSkinSwap.bat`。

脚本会保留仍然有效的文件，只补充或替换发生变化的资源。

## 卸载方法

双击 `Uninstall-TskSkinSwap.bat` 即可停止使用 MOD。

卸载不会删除已经下载的动画资源。若要同时释放约 2 GB 磁盘空间，可在卸载后删除 `TskSkinSwap\downloaded` 文件夹。

## 常见问题

### 提示游戏正在运行

请完全关闭游戏后重试。必要时打开任务管理器，确认 `twinkle_starknightsX.exe` 已退出。

### 双击后下载失败

确认网络可以访问 GitHub 和游戏官方 CDN，然后重新运行 BAT。已经成功下载的文件会被复用。

### 安装成功但动画没有变化

先确认测试角色拥有变身动画（R18），并实际触发“通常攻击 2”。游戏更新后出现此问题时，按“游戏更新后”的步骤重新应用 MOD。

### 如何恢复原版

运行 `Uninstall-TskSkinSwap.bat`，然后正常启动游戏即可。工具不会修改游戏原始资源文件。

## 资源说明

本仓库和 Release 不包含游戏动画资源。所需资源由脚本根据当前客户端信息，从游戏官方 CDN 下载并仅保存在用户本地。请勿重新分发下载得到的游戏资源。
