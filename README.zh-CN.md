# TskSkinSwap

该工具在通常攻击请求 `bc_<角色ID>` 骨骼时，改为使用变身演出的完整 `tf_<角色ID>_m0` SkeletonData，包括其骨骼、网格附件、skin、atlas 和材质。工具不会修改游戏的 Addressables 包或 Unity 缓存。

## 一键使用

1. 将整个仓库目录放到：

   ```text
   <游戏目录>\mods\TskSkinSwap\
   ```

2. 游戏更新后，先正常启动一次游戏以更新资源，然后关闭游戏。
3. 双击 `Apply-TskSkinSwap.bat`。
4. 窗口显示 `Completed successfully` 后正常启动游戏。

首次运行会从官方地址下载隔离的 Python、UnityPy、.NET SDK 和 BepInEx。之后脚本读取当前客户端的 Addressables 目录，只下载 MOD 所需的高画质成人版变身包和对应 Cutin 包，无需逐个打开角色的变身界面。成人版 Cutin 不存在时会自动回退到同 ID 的高画质 `general` Cutin。2026 年 7 月当前目录包含约 2.0 GiB 的相关游戏资源，请至少预留 2.1 GB 磁盘空间。

下载文件保存在 `downloaded/bundles/`，不会写入或修改游戏缓存。游戏更新后再次双击 BAT，目录中仍然有效的文件会直接复用，已变更的包会按新目录重新下载。

## 输出说明

- `transformBundles`：发现的高画质成人版变身包数量，包括自动下载和已有缓存。
- `matchedCharacters`：同时存在通常攻击 Cutin 和变身包的角色数量。
- `compatibleCharacters`：通过身体区域兼容检查并实际启用的数量。

因此三者不一定相等。未进入 `compatibleCharacters` 的角色不会被强制修改。

## 卸载

双击 `Uninstall-TskSkinSwap.bat`。卸载只移除插件和生成配置，不删除 BepInEx、自动下载文件，也不修改原始游戏或缓存文件。若要释放磁盘空间，可在卸载后手动删除 `downloaded/`。

## 发布注意

不要提交 `.tools/`、`downloaded/`、`generated/`、`src/bin/` 或 `src/obj/`。`downloaded/` 含有从当前客户端官方 CDN 获取的游戏资源，不得随 Git 仓库再分发。以上目录已经写入 `.gitignore`。第三方依赖及许可证说明见 `THIRD_PARTY.md`。
