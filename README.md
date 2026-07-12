# TskSkinSwap

This tool redirects a normal-attack `bc_<id>` SkeletonData request to the complete high-quality `tf_<id>_m0` transformation SkeletonData, including its mesh attachments, skin, atlas, and materials.

[简体中文说明](README.zh-CN.md)

## Update Workflow

1. Copy this directory to `<game>/mods/TskSkinSwap/`.
2. Start the game once after an update so Addressables refreshes its catalog and cache, then close it.
3. Double-click `Apply-TskSkinSwap.bat`.

The first run downloads isolated copies of embedded Python, UnityPy, the .NET 6 SDK, and BepInEx from their official sources. It then reads the installed client's current Addressables catalog and downloads only the high-quality adult transformation and matching Cutin bundles required by the mod. The July 2026 catalog requires about 2.0 GiB of game bundles, so allow at least 2.1 GB of free disk space. No system-wide Python or .NET SDK installation is required.

For a non-mutating compatibility scan from PowerShell:

   ```powershell
   .\mods\TskSkinSwap\Update-TskSkinSwap.ps1 -DryRun
   ```

To generate mappings and rebuild/install the runtime plugin directly from PowerShell:

   ```powershell
   .\mods\TskSkinSwap\Update-TskSkinSwap.ps1
   ```

Adult Cutin is preferred when available; otherwise the downloader automatically selects the matching high-quality general Cutin. Downloaded game bundles are stored under `downloaded/bundles/`, are never written into the game cache, and are excluded by `.gitignore`.

The update command restores the bundled BepInEx loader if game maintenance removed it, regenerates IL2CPP interop assemblies when needed, downloads missing bundles, scans both downloaded files and the current cache, builds the plugin, and installs the result. Existing valid downloads are reused after game updates.

## Safety and Rollback

The scanner never edits Addressables bundles or Unity cache files. Downloads use only URLs supplied by the installed client's catalog, and their declared size and required SkeletonData asset are validated before use. The runtime plugin reads bundles directly and replaces the skeleton data in memory. To disable it, remove `BepInEx/plugins/TskSkinSwap/TskSkinSwap.dll` or set a character's `enabled` value to `false`.

For a clean rollback:

```powershell
.\mods\TskSkinSwap\Uninstall-TskSkinSwap.ps1
```

Alternatively, double-click `Uninstall-TskSkinSwap.bat`.

Generated files live under `mods/TskSkinSwap/generated/` and `BepInEx/config/TskSkinSwap/`. Do not redistribute or commit `downloaded/`; it contains copyrighted game assets fetched for the local installation.
