from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

try:
    import UnityPy
except ImportError as exc:  # pragma: no cover - exercised by the launcher
    raise SystemExit("UnityPy is required: python -m pip install UnityPy") from exc


CUTIN_RE = re.compile(
    r"Assets/AssetBundles/Cutin/Characters/(?P<quality>HighQuality|LowQuality)/"
    r"(?P<edition>adult|general)/(?P<id>\d+)/bc_(?P=id)\.atlas\.txt$"
)
TRANSFORM_RE = re.compile(
    r"Assets/AssetBundles/GachaCharaAnim/(?P<quality>HighQuality|LowQuality)/"
    r"(?P<edition>adult|general)/tf_(?P<id>\d+)/tf_(?P=id)_m0\.atlas\.txt$"
)

ALIASES = {
    "b_arm_low_L": "nn_arm_low_L",
    "b_arm_up_L": "nn_arm_up_L",
    "b_arm_up_R": "nn_arm_up_R",
    "b_body_n": "body",
    "b_body_bust": "bust",
    "b_foot_01_L": "foot_01_L_",
    "b_foot_01_R": "foot_01_R",
    "b_foot_02_L": "foot_02_L",
    "b_foot_02_R": "foot_02_R",
    "b_weapon": "n_weapon",
}

HIDE_PATTERNS = (
    "clothes",
    "cloth",
    "clot",
    "coat",
    "sleeve",
    "belt",
    "feather",
)

CORE_REGIONS = {
    "b_arm_low_L",
    "b_arm_up_L",
    "b_arm_up_R",
    "b_body_n",
    "b_body_bust",
    "b_foot_01_L",
    "b_foot_01_R",
    "b_foot_02_L",
    "b_foot_02_R",
}


@dataclass(frozen=True)
class Atlas:
    header: list[str]
    regions: dict[str, list[str]]


@dataclass(frozen=True)
class BundleAssets:
    bundle_path: Path
    atlas_path: str
    atlas_text: str
    edition: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate TSK Spine skin-swap mappings.")
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--bundle-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--quality", default="HighQuality", choices=("HighQuality", "LowQuality"))
    parser.add_argument("--edition", default="adult", choices=("adult", "general"))
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def default_cache_dir() -> Path:
    return Path.home() / "AppData/LocalLow/Unity/FANZAGAMES_twinkle_starknightsX"


def raw_bytes(value: object) -> bytes:
    if isinstance(value, str):
        return value.encode("utf-8", "surrogateescape")
    return bytes(value)


def parse_atlas(text: str) -> Atlas:
    lines = text.replace("\r\n", "\n").splitlines()
    if len(lines) < 4:
        raise ValueError("atlas has no page header")

    header = lines[:4]
    regions: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines[4:]:
        if line and not line[0].isspace() and ":" not in line:
            current = line.strip()
            regions[current] = []
        elif current is not None and line.strip():
            regions[current].append(line.strip())
    return Atlas(header=header, regions=regions)


def render_page(header: list[str], regions: Iterable[tuple[str, list[str]]]) -> list[str]:
    output = list(header)
    for name, properties in regions:
        output.append(name)
        output.extend(properties)
    return output


def transparent_properties(source: list[str]) -> list[str]:
    original_size = "1,1"
    for prop in source:
        if prop.startswith("offsets:"):
            values = prop.removeprefix("offsets:").split(",")
            if len(values) == 4:
                original_size = f"{values[2]},{values[3]}"
        elif prop.startswith("bounds:") and original_size == "1,1":
            values = prop.removeprefix("bounds:").split(",")
            if len(values) == 4:
                original_size = f"{values[2]},{values[3]}"
    return ["bounds:0,0,1,1", f"offsets:0,0,{original_size}"]


def normalized_region_name(name: str) -> str:
    value = name.lower().strip().replace(" ", "_")
    for prefix in ("nn_", "n_", "u_", "b_"):
        if value.startswith(prefix):
            return value[len(prefix) :]
    return value


def synthetic_atlas(cutin: Atlas, transform: Atlas) -> tuple[str, dict[str, object]]:
    transformed: list[tuple[str, list[str]]] = []
    preserved: list[tuple[str, list[str]]] = []
    hidden: list[tuple[str, list[str]]] = []
    aliases_used: dict[str, str] = {}
    unsupported: list[str] = []
    normalized_transform: dict[str, list[str]] = {}
    for transform_name in transform.regions:
        normalized_transform.setdefault(normalized_region_name(transform_name), []).append(transform_name)

    for name, properties in cutin.regions.items():
        source_name = name if name in transform.regions else ALIASES.get(name)
        if (not source_name or source_name not in transform.regions) and name in CORE_REGIONS:
            candidates = normalized_transform.get(normalized_region_name(name), [])
            if len(candidates) == 1:
                source_name = candidates[0]
        if source_name and source_name in transform.regions:
            transformed.append((name, transform.regions[source_name]))
            if source_name != name:
                aliases_used[name] = source_name
            continue

        lower_name = name.lower()
        if any(pattern in lower_name for pattern in HIDE_PATTERNS):
            hidden.append((name, transparent_properties(properties)))
            continue

        preserved.append((name, properties))
        if name in CORE_REGIONS:
            unsupported.append(name)

    tf_header = list(transform.header)
    bc_header = list(cutin.header)
    transparent_header = ["transparent.png", "size:2,2", "filter:Linear,Linear", "repeat:none"]
    lines: list[str] = []
    lines.extend(render_page(tf_header, transformed))
    lines.append("")
    lines.extend(render_page(bc_header, preserved))
    lines.append("")
    lines.extend(render_page(transparent_header, hidden))
    lines.append("")

    core_mapped = len(CORE_REGIONS - set(unsupported))
    score = core_mapped / len(CORE_REGIONS)
    report = {
        "score": round(score, 4),
        "compatible": not unsupported and score >= 0.8,
        "aliases": aliases_used,
        "transformedRegions": len(transformed),
        "preservedRegions": len(preserved),
        "hiddenRegions": [name for name, _ in hidden],
        "unsupportedCoreRegions": unsupported,
    }
    return "\n".join(lines), report


def read_text_asset(environment: object, asset_path: str) -> str:
    for path, obj in environment.container.items():
        if str(path) == asset_path:
            value = obj.read().m_Script
            return raw_bytes(value).decode("utf-8", "replace")
    raise KeyError(asset_path)


def scan_bundles(
    cache_dir: Path,
    bundle_dir: Path | None,
    quality: str,
    edition: str,
) -> tuple[dict[str, BundleAssets], dict[str, BundleAssets], list[str]]:
    cutins: dict[str, BundleAssets] = {}
    cutin_priorities: dict[str, int] = {}
    transforms: dict[str, BundleAssets] = {}
    errors: list[str] = []

    files = list(cache_dir.rglob("__data"))
    if bundle_dir and bundle_dir.exists():
        files.extend(bundle_dir.rglob("*.bundle"))
    files.sort(key=lambda item: item.stat().st_mtime, reverse=True)
    for bundle_path in files:
        try:
            environment = UnityPy.load(str(bundle_path))
            paths = [str(path) for path in environment.container.keys()]
        except Exception as exc:  # corrupted or non-Unity cache entry
            errors.append(f"{bundle_path}: {type(exc).__name__}: {exc}")
            continue

        for asset_path in paths:
            match = CUTIN_RE.search(asset_path)
            is_cutin = match is not None
            if not is_cutin:
                match = TRANSFORM_RE.search(asset_path)
            if match is None or match["quality"] != quality:
                continue

            character_id = match["id"]
            asset_edition = match["edition"]
            if is_cutin:
                allowed = asset_edition == edition or (edition == "adult" and asset_edition == "general")
                if not allowed:
                    continue
                priority = 2 if asset_edition == edition else 1
                if priority <= cutin_priorities.get(character_id, 0):
                    continue
            else:
                if asset_edition != edition or character_id in transforms:
                    continue
            try:
                atlas_text = read_text_asset(environment, asset_path)
            except Exception as exc:
                errors.append(f"{bundle_path}: cannot read {asset_path}: {exc}")
                continue
            asset = BundleAssets(bundle_path, asset_path, atlas_text, asset_edition)
            if is_cutin:
                cutins[character_id] = asset
                cutin_priorities[character_id] = priority
            else:
                transforms[character_id] = asset

    return cutins, transforms, errors


def sha256(path: Path) -> str | None:
    if not path.exists():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sibling_asset(atlas_path: str, suffix: str) -> str:
    return atlas_path.removesuffix(".atlas.txt") + suffix


def main() -> int:
    args = parse_args()
    game_dir = args.game_dir.resolve()
    cache_dir = (args.cache_dir or default_cache_dir()).resolve()
    bundle_dir = args.bundle_dir.resolve() if args.bundle_dir else None
    output_dir = args.output_dir.resolve()

    if not (game_dir / "GameAssembly.dll").exists():
        raise SystemExit(f"Not a TSK game directory: {game_dir}")
    if not cache_dir.exists():
        raise SystemExit(f"Unity cache directory does not exist: {cache_dir}")

    cutins, transforms, errors = scan_bundles(cache_dir, bundle_dir, args.quality, args.edition)
    common_ids = sorted(set(cutins) & set(transforms))
    characters: list[dict[str, object]] = []
    atlas_outputs: dict[str, str] = {}

    for character_id in common_ids:
        cutin_asset = cutins[character_id]
        transform_asset = transforms[character_id]
        atlas_name = ""
        try:
            combined, report = synthetic_atlas(
                parse_atlas(cutin_asset.atlas_text),
                parse_atlas(transform_asset.atlas_text),
            )
            atlas_name = f"bc_{character_id}_synthetic.atlas.txt"
            atlas_outputs[atlas_name] = combined
        except Exception as exc:
            report = {
                "score": 1.0,
                "compatible": True,
                "aliases": {},
                "transformedRegions": 0,
                "preservedRegions": 0,
                "hiddenRegions": [],
                "unsupportedCoreRegions": [],
                "atlasDiagnosticError": f"{type(exc).__name__}: {exc}",
            }

        report["mode"] = "fullSkeleton"
        report["compatible"] = True
        report["score"] = 1.0
        characters.append(
            {
                "characterId": character_id,
                "enabled": True,
                "cutinBundle": str(cutin_asset.bundle_path),
                "transformBundle": str(transform_asset.bundle_path),
                "cutinEdition": cutin_asset.edition,
                "transformEdition": transform_asset.edition,
                "cutinAtlasAsset": cutin_asset.atlas_path,
                "transformAtlasAsset": transform_asset.atlas_path,
                "transformMaterialAsset": sibling_asset(transform_asset.atlas_path, "_Material.mat"),
                "transformSkeletonAsset": sibling_asset(transform_asset.atlas_path, "_SkeletonData.asset"),
                "syntheticAtlasFile": atlas_name,
                "report": report,
            }
        )

    catalog = game_dir / "twinkle_starknightsX_Data/StreamingAssets/aa/catalog.bundle"
    remote_catalog = (
        Path.home()
        / "AppData/LocalLow/FANZAGAMES/twinkle_starknightsX/com.unity.addressables/catalog_0.0.0.json"
    )
    payload = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "quality": args.quality,
        "edition": args.edition,
        "gameDirectory": str(game_dir),
        "cacheDirectory": str(cache_dir),
        "downloadDirectory": str(bundle_dir) if bundle_dir else None,
        "gameAssemblySha256": sha256(game_dir / "GameAssembly.dll"),
        "catalogSha256": sha256(remote_catalog) or sha256(catalog),
        "statistics": {
            "cutinBundles": len(cutins),
            "transformBundles": len(transforms),
            "matchedCharacters": len(common_ids),
            "compatibleCharacters": sum(1 for item in characters if item["enabled"]),
            "scanErrors": len(errors),
        },
        "characters": characters,
        "errors": errors[:200],
    }

    print(json.dumps(payload["statistics"], ensure_ascii=False, indent=2))
    for item in characters:
        status = "enabled" if item["enabled"] else "disabled"
        report = item["report"]
        reason = ""
        if report["unsupportedCoreRegions"]:
            reason = f" missing={','.join(report['unsupportedCoreRegions'])}"
        print(f"{item['characterId']}: {status} score={report['score']}{reason}")
    if args.dry_run:
        return 0

    atlas_dir = output_dir / "atlases"
    atlas_dir.mkdir(parents=True, exist_ok=True)
    for name, content in atlas_outputs.items():
        (atlas_dir / name).write_text(content, encoding="utf-8", newline="\n")
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "mappings.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
