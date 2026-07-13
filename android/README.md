# Android Development

## Current Status

Android 0.2.8 is the current formal Android release. A phone-only installer is under development; the current release still requires a Windows PC and USB debugging.

## Installation Architecture

`Apply-TskSkinSwap-Android.bat` now performs the complete PC-assisted flow without root access:

1. Download the latest standard Kurusuta APK from `anosu/DMM-Mod` through the GitHub Release API and validate GitHub's size and SHA-256 metadata.
2. Validate the package name, version, signer, Frida Gadget, and embedded translation script.
3. Combine the translation and TskSkinSwap Frida bundles in isolated scopes, replace only `lib/arm64-v8a/libfrida-gadget.script.so`, align the APK, and sign it with Objection's pinned, publicly available development key.
4. Install with `adb install -r`; never uninstall or clear application data.
5. Reuse valid bundles from `UnityCache/Shared` or MOD storage, download only missing transformation bundles from the catalog's official URLs, write `mappings.json`, and launch the game.

APK files, signing tools, game assets, generated mappings, and downloaded bundles remain local and untracked. `-DryRun` inventories the current catalog and cache without patching the APK or downloading resources.

## Development Commands

```powershell
cd android
npm ci
npm run build
cd ..
.\Apply-TskSkinSwap-Android.ps1 -DryRun
.\Build-TskSkinSwap-AndroidApk.ps1 -InputApk <compatible.apk> -SkipRuntimeBuild
```

The runtime reads `<persistentDataPath>/tskskinswap/mappings.json`. It observes `EffectCutinManager.LoadCutin` to preload only needed transformation assets, then replaces that manager's `cutinData` entry during `SetNormalCutin`. Do not patch `SkeletonDataAsset.GetSkeletonData`; those assets are shared with the home screen.

Both Normal Attack 1 and Normal Attack 2 use the replacement. Lulu (`1141001`) remains excluded. Uninstall restores the cached, unmodified compatible APK with `adb install -r` and keeps downloaded transformation bundles by default.
