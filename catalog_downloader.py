from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import struct
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

try:
    import UnityPy
except ImportError:  # Android catalog discovery does not inspect bundle contents.
    UnityPy = None


TRANSFORM_TARGET_RE = re.compile(
    r"^Assets/AssetBundles/GachaCharaAnim/(?P<quality>HighQuality|LowQuality)/"
    r"(?P<edition>adult|general)/tf_(?P<id>\d+)/"
    r"tf_(?P=id)_m0_SkeletonData\.asset$"
)
CUTIN_TARGET_RE = re.compile(
    r"^Assets/AssetBundles/Cutin/Characters/(?P<quality>HighQuality|LowQuality)/"
    r"(?P<edition>adult|general)/(?P<id>\d+)/bc_(?P=id)_SkeletonData\.asset$"
)


@dataclass(frozen=True)
class Bucket:
    data_offset: int
    entries: tuple[int, ...]


@dataclass(frozen=True)
class Entry:
    internal_id: int
    provider: int
    dependency_key: int
    dependency_hash: int
    extra_data: int
    primary_key: int
    resource_type: int


@dataclass(frozen=True)
class BundleTarget:
    kind: str
    character_id: str
    edition: str
    asset_path: str
    url: str
    size: int
    catalog_hash: str
    crc: int
    bundle_name: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Download TSK transform bundles from the current catalog.")
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--quality", default="HighQuality", choices=("HighQuality", "LowQuality"))
    parser.add_argument("--edition", default="adult", choices=("adult", "general"))
    parser.add_argument("--character-id", action="append", default=[])
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def int32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<i", data, offset)[0]


def read_object(data: bytes, offset: int) -> object:
    object_type = data[offset]
    offset += 1
    if object_type in (0, 1):
        length = int32(data, offset)
        encoding = "ascii" if object_type == 0 else "utf-16-le"
        return data[offset + 4 : offset + 4 + length].decode(encoding)
    if object_type == 2:
        return struct.unpack_from("<H", data, offset)[0]
    if object_type == 3:
        return struct.unpack_from("<I", data, offset)[0]
    if object_type == 4:
        return int32(data, offset)
    if object_type in (5, 6):
        length = data[offset]
        return data[offset + 1 : offset + 1 + length].decode("ascii")
    if object_type == 7:
        assembly_length = data[offset]
        offset += 1 + assembly_length
        class_length = data[offset]
        offset += 1 + class_length
        json_length = int32(data, offset)
        raw_json = data[offset + 4 : offset + 4 + json_length].decode("utf-16-le")
        return json.loads(raw_json)
    raise ValueError(f"Unsupported catalog object type {object_type} at offset {offset - 1}")


def decode_buckets(catalog: dict[str, object]) -> list[Bucket]:
    data = base64.b64decode(str(catalog["m_BucketDataString"]))
    count = int32(data, 0)
    offset = 4
    buckets: list[Bucket] = []
    for _ in range(count):
        data_offset = int32(data, offset)
        entry_count = int32(data, offset + 4)
        offset += 8
        entries = struct.unpack_from(f"<{entry_count}i", data, offset) if entry_count else ()
        offset += entry_count * 4
        buckets.append(Bucket(data_offset, tuple(entries)))
    return buckets


def decode_entries(catalog: dict[str, object]) -> list[Entry]:
    data = base64.b64decode(str(catalog["m_EntryDataString"]))
    count = int32(data, 0)
    return [Entry(*struct.unpack_from("<7i", data, 4 + index * 28)) for index in range(count)]


def expand_internal_id(catalog: dict[str, object], value: str) -> str:
    marker = value.rfind("#")
    if marker < 0:
        return value
    try:
        prefix_index = int(value[:marker])
    except ValueError:
        return value
    prefixes = catalog.get("m_InternalIdPrefixes") or []
    if not 0 <= prefix_index < len(prefixes):
        return value
    return str(prefixes[prefix_index]) + value[marker + 1 :]


def catalog_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def discover_targets(
    catalog_path: Path,
    quality: str,
    edition: str,
    require_cutins: bool = True,
) -> tuple[str, list[BundleTarget]]:
    with catalog_path.open("r", encoding="utf-8-sig") as stream:
        catalog = json.load(stream)

    buckets = decode_buckets(catalog)
    key_data = base64.b64decode(str(catalog["m_KeyDataString"]))
    keys = [read_object(key_data, bucket.data_offset) for bucket in buckets]
    entries = decode_entries(catalog)
    extra_data = base64.b64decode(str(catalog["m_ExtraDataString"]))
    providers = catalog["m_ProviderIds"]
    internal_ids = catalog["m_InternalIds"]
    transforms: dict[str, BundleTarget] = {}
    cutins: dict[tuple[str, str], BundleTarget] = {}

    for entry in entries:
        primary_key = keys[entry.primary_key]
        if not isinstance(primary_key, str):
            continue
        transform_match = TRANSFORM_TARGET_RE.fullmatch(primary_key)
        cutin_match = CUTIN_TARGET_RE.fullmatch(primary_key)
        match = transform_match or cutin_match
        if match is None or match["quality"] != quality:
            continue
        if transform_match is not None and match["edition"] != edition:
            continue
        if entry.dependency_key < 0:
            continue

        bundle_entries = buckets[entry.dependency_key].entries
        bundle_entry = next(
            (
                entries[index]
                for index in bundle_entries
                if str(providers[entries[index].provider]).endswith("AssetBundleProvider")
            ),
            None,
        )
        if bundle_entry is None or bundle_entry.extra_data < 0:
            raise ValueError(f"No bundle dependency found for {primary_key}")

        options = read_object(extra_data, bundle_entry.extra_data)
        if not isinstance(options, dict):
            raise ValueError(f"Invalid bundle options for {primary_key}")
        url = expand_internal_id(catalog, str(internal_ids[bundle_entry.internal_id]))
        if not url.startswith(("https://", "http://")):
            raise ValueError(f"Refusing non-HTTP bundle location for {primary_key}: {url}")

        target = BundleTarget(
            kind="transform" if transform_match is not None else "cutin",
            character_id=match["id"],
            edition=match["edition"],
            asset_path=primary_key,
            url=url,
            size=int(options.get("m_BundleSize", 0)),
            catalog_hash=str(options.get("m_Hash", "")),
            crc=int(options.get("m_Crc", 0)),
            bundle_name=str(options.get("m_BundleName", "")),
        )
        target_key: object = target.character_id if target.kind == "transform" else (target.character_id, target.edition)
        collection = transforms if target.kind == "transform" else cutins
        previous = collection.get(target_key)
        if previous is not None and previous.url != target.url:
            raise ValueError(f"Multiple {target.kind} bundles found for character {target.character_id}")
        collection[target_key] = target

    targets: list[BundleTarget] = []
    missing_cutins: list[str] = []
    for character_id, transform in sorted(transforms.items()):
        targets.append(transform)
        if not require_cutins:
            continue
        cutin = cutins.get((character_id, edition))
        if cutin is None and edition == "adult":
            cutin = cutins.get((character_id, "general"))
        if cutin is None:
            missing_cutins.append(character_id)
        else:
            targets.append(cutin)
    if missing_cutins:
        raise ValueError(f"No compatible Cutin bundle for: {', '.join(missing_cutins)}")
    return catalog_sha256(catalog_path), targets


def contains_asset(path: Path, asset_path: str) -> bool:
    if UnityPy is None:
        raise RuntimeError("UnityPy is required to inspect bundle contents")
    environment = UnityPy.load(path.read_bytes())
    return any(str(container_path) == asset_path for container_path in environment.container)


def validate_bundle(path: Path, target: BundleTarget) -> None:
    actual_size = path.stat().st_size
    if target.size and actual_size != target.size:
        raise ValueError(f"size mismatch: expected {target.size}, received {actual_size}")
    if not contains_asset(path, target.asset_path):
        raise ValueError(f"bundle does not contain {target.asset_path}")


def download(target: BundleTarget, destination: Path) -> None:
    temporary = destination.with_suffix(destination.suffix + ".part")
    temporary.unlink(missing_ok=True)
    request = urllib.request.Request(target.url, headers={"User-Agent": "TskSkinSwap/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
            if response.status != 200:
                raise ValueError(f"HTTP {response.status}")
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        validate_bundle(temporary, target)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def file_name(target: BundleTarget) -> str:
    identity = target.catalog_hash or hashlib.sha256(target.url.encode("utf-8")).hexdigest()
    if target.kind == "transform":
        return f"tf_{target.character_id}_{identity}.bundle"
    return f"bc_{target.character_id}_{target.edition}_{identity}.bundle"


def main() -> int:
    args = parse_args()
    catalog_path = args.catalog.resolve()
    output_dir = args.output_dir.resolve()
    if not catalog_path.is_file():
        raise SystemExit(f"Addressables catalog does not exist: {catalog_path}")

    catalog_hash, targets = discover_targets(catalog_path, args.quality, args.edition)
    if args.character_id:
        selected_ids = set(args.character_id)
        targets = [target for target in targets if target.character_id in selected_ids]
        missing_ids = selected_ids - {target.character_id for target in targets}
        if missing_ids:
            raise SystemExit(f"Characters not found in the selected catalog group: {', '.join(sorted(missing_ids))}")
    if not targets:
        raise SystemExit(f"No {args.quality}/{args.edition} transform bundles were found in the catalog")

    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = output_dir / "manifest.json"
    downloaded = 0
    reused = 0
    failed: list[str] = []
    records: list[dict[str, object]] = []
    expected_files = {file_name(target) for target in targets}

    character_count = len({target.character_id for target in targets})
    print(f"Catalog contains {character_count} characters and {len(targets)} required bundles.")
    for index, target in enumerate(targets, start=1):
        destination = output_dir / file_name(target)
        status = "available"
        try:
            if destination.is_file():
                try:
                    validate_bundle(destination, target)
                    reused += 1
                except Exception:
                    if args.dry_run:
                        raise
                    destination.unlink()
                    print(f"[{index}/{len(targets)}] Replacing invalid bundle for character {target.character_id}...")
                    download(target, destination)
                    downloaded += 1
            elif args.dry_run:
                status = "missing"
            else:
                print(
                    f"[{index}/{len(targets)}] Downloading {target.kind} for character "
                    f"{target.character_id} ({target.size / 1048576:.1f} MiB)..."
                )
                download(target, destination)
                downloaded += 1
        except Exception as exc:
            status = "failed"
            failed.append(f"{target.character_id}: {type(exc).__name__}: {exc}")
        records.append(
            {
                "characterId": target.character_id,
                "kind": target.kind,
                "edition": target.edition,
                "assetPath": target.asset_path,
                "url": target.url,
                "file": file_name(target),
                "size": target.size,
                "hash": target.catalog_hash,
                "crc": target.crc,
                "bundleName": target.bundle_name,
                "status": status,
            }
        )

    if not args.dry_run:
        if not args.character_id:
            for pattern in ("tf_*.bundle", "bc_*.bundle"):
                for obsolete in output_dir.glob(pattern):
                    if obsolete.name not in expected_files:
                        obsolete.unlink()
        manifest_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "catalogSha256": catalog_hash,
                    "quality": args.quality,
                    "edition": args.edition,
                    "bundles": records,
                    "errors": failed,
                },
                ensure_ascii=False,
                indent=2,
            )
            + "\n",
            encoding="utf-8",
            newline="\n",
        )

    print(f"Required bundles: reused={reused} downloaded={downloaded} failed={len(failed)}")
    for error in failed:
        print(error, file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
