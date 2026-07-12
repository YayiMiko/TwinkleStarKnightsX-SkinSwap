# Android Development

## User Installation

The current installer targets the compatible Android package (APK) named `jp.co.fanzagames.twinklestarknightsx_a_mod`, with Frida Gadget `script-directory` support. Root access is not required. Enable USB debugging, connect and authorize the phone, then double-click:

```text
Apply-TskSkinSwap-Android.bat
```

The launcher downloads portable Python and Android Platform Tools when they are unavailable. It pulls only the current Addressables catalog, checks the exact transform paths under `UnityCache/Shared`, and reuses valid cache files in place. Missing transform bundles are downloaded on the PC from the catalog's official CDN URL, validated as UnityFS files, and pushed to `<persistentDataPath>/tskskinswap/bundles/`.

Rerunning the installer after an update reuses valid UnityCache and MOD-owned files. The July 2026 test catalog contains 267 mappings; the test device reused 56 cached transforms and required about 0.66 GiB for the remaining 211. Run a read-only inventory with:

```powershell
.\Apply-TskSkinSwap-Android.ps1 -DryRun
```

The installer does not pull, copy, or rewrite the phone's existing multi-gigabyte game data. APK patching is not yet part of this launcher.

## Runtime Development

The Android runtime is an autonomous Frida Gadget script for the ARM64 IL2CPP client. It is loaded beside the existing translation script through Gadget's `script-directory` interaction.

```powershell
cd android
npm install
npm run build
```

Runtime configuration is read from `<persistentDataPath>/tskskinswap/mappings.json`. Bundle paths may point directly to valid Unity cache entries, allowing the installer to reuse game data instead of copying it.

The runtime observes `EffectCutinManager.LoadCutin` to preload only the transform assets needed by the active Cutin view. When `SetNormalCutin` runs, it replaces that manager's `cutinData` entry with the prepared transform `SkeletonDataAsset`. Do not patch `SkeletonDataAsset.GetSkeletonData`: those assets are shared with the home screen and global mutation corrupts unrelated Spine views.

The current runtime replaces the Cutin used by both Normal Attack 1 and Normal Attack 2 in battle and in the non-battle animation preview. Returning to the home screen and entering a second battle do not retain the replacement outside the Cutin manager. A future optional mode may restrict replacement to Normal Attack 2 only.

APK files, signing tools, extracted game content, generated scripts, mappings, and downloaded bundles must remain untracked.
