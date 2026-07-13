# Twinkle Star Knights Normal Attack Cutin Mod

This mod replaces the character cutin shown during both Normal Attack 1 and Normal Attack 2 with the supported character's high-quality R18 transformation animation. It does not change the actual attack action, damage, or battle speed. The PC edition is available as a formal release; Android is currently a Dev test release.

A future optional edition may limit the replacement to Normal Attack 2 only.

Lulu (`[炎宿せし宝石] ルルゥ`, internal ID `1141001`) is currently excluded on both platforms. Her original normal-attack presentation remains active.

[简体中文](README.md)

## PC Release 1.2.2

1. Download `TskSkinSwap-PC-v1.2.2.zip` from [PC Release 1.2.2](https://github.com/YayiMiko/TSKSkinSwap/releases/tag/pc-v1.2.2).
2. Extract `TskSkinSwap` to `<game>/mods/TskSkinSwap/`.
3. Close the game and double-click `Apply-TskSkinSwap.bat`.
4. Start the game after `Completed successfully` appears.

The release includes the compiled plugin and does not require a .NET SDK. The first installation downloads about 1 GB. Run the BAT again after a game update. Updates are staged and validated before replacing the working installation.

To upgrade from an older PC release, you do not need to uninstall it. Close the game, replace the old `TskSkinSwap` folder with the fully extracted 1.2.2 folder, and run the new `Apply-TskSkinSwap.bat`. Existing valid downloads will be reused.

## Android 0.2.2 Dev Test Release

The Android installer works with the verified public compatible APK and preserves the translation and existing game data. It has been tested on a vivo X100 Pro running Android 16. See [the Android instructions](README.android.md) before using the [0.2.2 Dev release](https://github.com/YayiMiko/TSKSkinSwap/releases/tag/android-dev-20260714.2).

## Uninstall

Close the game and run `Uninstall-TskSkinSwap.bat`. Choose `Complete uninstall` to remove the mod, downloaded resources, local tools, and the `mods/TskSkinSwap` folder. BepInEx is also removed when TskSkinSwap installed it and no other add-ons use it. Choose `Disable only` to keep downloads for a faster reinstall. The mod does not replace the game's original animation files.

## Game Resources

Releases do not contain game animations, compatible Android packages (APK), or generated mappings. Do not redistribute game resources downloaded by the installer.
