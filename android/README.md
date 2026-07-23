# Android Development

## Current Status

Android 0.4.0 is the current formal Android release. It dynamically discovers the latest compatible APK. A phone-only installer is under development; the current flow still requires a Windows PC and USB debugging.

## Installation Architecture

`Apply-TskSkinSwap-Android.bat` now performs the complete PC-assisted flow without root access:

1. Query `anosu/DMM-Mod` releases for the newest standard Kurusuta APK and validate the downloaded file against GitHub's size and SHA-256 metadata.
2. Validate the package name, version, signer, Frida Gadget, and embedded translation script.
3. Combine the translation and TskSkinSwap Frida bundles in isolated scopes, replace only `lib/arm64-v8a/libfrida-gadget.script.so`, align the APK, and sign it with Objection's pinned, publicly available development key.
4. Refuse downgrades. When a newer compatible app is found, install it with `adb install -r`, launch it, and require the user to finish the in-game update before rerunning the BAT.
5. On the second run, reuse valid bundles from `UnityCache/Shared` or MOD storage, download only missing transformation bundles from the current catalog's official URLs, write `mappings.json`, and launch the game.

APK files, signing tools, game assets, generated mappings, and downloaded bundles remain local and untracked. `-DryRun` inventories the current catalog and cache without patching the APK or downloading resources.

The packaged ADB client is extracted to `%TEMP%/TskSkinSwap/android-platform-tools/` before use. The ADB server therefore never executes from the release folder, so a lingering daemon cannot prevent that folder from being deleted.

## Development Commands

```powershell
cd android
npm ci
npm run build
cd ..
.\Apply-TskSkinSwap-Android.ps1 -DryRun
.\Build-TskSkinSwap-AndroidApk.ps1 -InputApk <compatible.apk> -SkipRuntimeBuild
```

The runtime reads `<persistentDataPath>/tskskinswap/mappings.json`. It observes `EffectCutinManager.LoadCutin`, requests transformation skeletons through the game's `AddressableWrapper<SkeletonDataAsset>`, and registers a temporary override during `SetNormalCutin`. `GetSkeletonData` and `GetAnimationStateData` serve the prepared data only for that request; `SkeletonGraphic.Initialize` then restores the original fields. The manager's `cutinData` dictionary is never replaced.

Only Normal Attack 2 uses the replacement; Normal Attack 1 keeps the game's original presentation. Lulu (`[炎宿せし宝石] ルルゥ`) remains excluded. Uninstall restores the cached, unmodified compatible APK with `adb install -r` and keeps downloaded transformation bundles by default.
