# TskSkinSwap

TskSkinSwap is an R18 animation replacement mod for the PC version of Twinkle Star Knights X. It replaces each supported character's Normal Attack 2 animation with that character's high-quality R18 transformation animation.

[简体中文](README.md)

## One-Click Installation

1. Download `TskSkinSwap-v0.5.0.zip` from [Releases](https://github.com/YayiMiko/TwinkleStarKnightsX-SkinSwap/releases).
2. Extract the `TskSkinSwap` folder to `<game>/mods/TskSkinSwap/`.
3. Start the game once after an update so Addressables refreshes its catalog, then close it.
4. Double-click `Apply-TskSkinSwap.bat`.

The first run downloads isolated copies of Python, UnityPy, the .NET 6 SDK, and BepInEx from their official sources. It then reads the installed client's current Addressables catalog and downloads the high-quality R18 transformation and matching Cutin bundles required by the mod.

Adult Cutin is preferred when available; otherwise the downloader selects the matching high-quality general Cutin. The July 2026 catalog requires about 2.0 GiB of game bundles, so allow at least 2.1 GB of free disk space.

## Updates and Safety

Run `Apply-TskSkinSwap.bat` again after a game update. Existing valid downloads are reused, while changed bundles are downloaded from the URLs in the current client catalog.

Downloaded files are stored under `downloaded/bundles/`. Their declared size, UnityFS structure, and required SkeletonData asset are validated before use. The tool never modifies the game's Addressables bundles or Unity cache.

## Uninstall

Double-click `Uninstall-TskSkinSwap.bat`. The uninstaller leaves BepInEx and downloaded bundles in place. Delete `downloaded/` manually if you also want to reclaim disk space.

## Distribution

Do not commit or redistribute `.tools/`, `downloaded/`, `generated/`, `src/bin/`, or `src/obj/`. The `downloaded/` directory contains copyrighted game assets fetched from the official CDN. See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency licenses.
