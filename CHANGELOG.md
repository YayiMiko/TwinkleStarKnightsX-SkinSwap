# 更新记录

## 0.6.0-beta.1 - 2026-07-12

首个 Android 预发布版本。

- 支持战斗和非战斗预览中的“通常攻击 2”成人变身动画替换。
- 通过战斗 Cutin 管理器隔离替换，避免影响主页和其他 Spine 界面。
- 自动解析 Android Addressables Catalog，生成 267 个角色映射。
- 优先直接复用 UnityCache，只下载缺失的高画质成人变身 Bundle。
- 支持断点续传、UnityFS 校验、推送后大小复核和并发安装保护。
- 提供 Windows 一键安装与安全卸载脚本，无需 Root。
- 变身资产准备完成后释放 MOD 的 Bundle 容器，避免与原始变身场景的 Addressables 加载冲突。
- 独立补偿替换动画的背景骨骼缩放，避免超宽 Android 屏幕在角色缩放时露出战斗背景。

已在 vivo X100s Pro、Android 16、游戏 `01.03.02` 上验证。当前安装器要求预先安装带 Frida Gadget `script-directory` 支持的兼容 Mod APK。
