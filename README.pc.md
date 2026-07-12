# 闪耀星骑士 PC 动画替换 MOD

这是 PC 版 Release 1.1。安装后，支持角色的“通常攻击 2”会替换为该角色的高画质成人变身动画（R18）。

## 使用条件

- Windows PC 版《闪耀星骑士》。
- 首次安装需要联网，并预留约 2.1 GB 磁盘空间。
- 安装或更新 MOD 前必须完全关闭游戏。

## 安装

1. 完整解压 `TskSkinSwap-PC-v1.1.0.zip`。
2. 打开游戏目录。如果其中没有 `mods` 文件夹，请自行新建一个。
3. 将解压出的 `TskSkinSwap` 文件夹放入：

   ```text
   <游戏目录>\mods\TskSkinSwap\
   ```

4. 进入 `<游戏目录>\mods\TskSkinSwap\`，双击该文件夹里的 `Apply-TskSkinSwap.bat`。
5. 等待窗口显示 `Completed successfully`，然后启动游戏。

首次运行会自动准备运行组件和动画资源。以后正常启动游戏即可，无需每次运行安装工具。

## 从 PC 版 1.0 升级

无需先卸载 1.0。

1. 完全关闭游戏。
2. 下载并完整解压 `TskSkinSwap-PC-v1.1.0.zip`。
3. 用新的 `TskSkinSwap` 文件夹覆盖原来的 `<游戏目录>\mods\TskSkinSwap\`。
4. 双击新版文件夹中的 `Apply-TskSkinSwap.bat`。
5. 显示 `Completed successfully` 后启动游戏。

安装工具会复用已经下载且仍然有效的资源，不会无条件重新下载全部内容。

## 游戏更新后

先正常启动游戏一次并完成更新，然后关闭游戏，再次双击 `Apply-TskSkinSwap.bat`。工具只会补充或替换发生变化的文件。

## 卸载

双击 `Uninstall-TskSkinSwap.bat`。若还要释放下载资源占用的空间，可在卸载后删除 `TskSkinSwap\downloaded` 文件夹。

## 常见问题

### 提示游戏正在运行

关闭游戏后重试。必要时在任务管理器中确认 `twinkle_starknightsX.exe` 已退出。

### 下载失败

确认电脑可以访问 GitHub 和游戏官方资源服务器，然后重新运行 BAT。已完成的文件不会重复下载。

### 动画没有变化

确认角色拥有成人变身动画，并实际触发“通常攻击 2”。游戏更新后请重新应用 MOD。

## 资源说明

下载包不包含游戏动画。安装工具会根据当前客户端获取资源并仅保存在本机，请勿重新分发这些资源。
