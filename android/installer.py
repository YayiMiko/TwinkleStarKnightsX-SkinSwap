from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from catalog_downloader import BundleTarget, discover_targets, file_name


DEFAULT_PACKAGE = "jp.co.fanzagames.twinklestarknightsx_a_mod"
CATALOG_NAME = "catalog_0.0.0.json"


@dataclass(frozen=True)
class RemoteFile:
    size: int
    is_unityfs: bool


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Install TskSkinSwap on a connected Android device.")
    parser.add_argument("--adb", type=Path, default=Path("adb"))
    parser.add_argument("--package", default=DEFAULT_PACKAGE)
    parser.add_argument("--package-version-name")
    parser.add_argument("--script", type=Path)
    parser.add_argument("--output-dir", type=Path, default=root / "downloaded" / "android")
    parser.add_argument("--quality", choices=("HighQuality", "LowQuality"), default="HighQuality")
    parser.add_argument("--edition", choices=("adult", "general"), default="adult")
    parser.add_argument("--character-id", action="append", default=[])
    parser.add_argument("--embedded-runtime", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-restart", action="store_true")
    return parser.parse_args()


class Adb:
    def __init__(self, executable: Path) -> None:
        self.executable = str(executable)

    def run(self, *arguments: str, capture: bool = True) -> str:
        result = subprocess.run(
            [self.executable, *arguments],
            check=False,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip()
            raise RuntimeError(f"adb {' '.join(arguments)} failed: {detail}")
        return (result.stdout or "").strip()

    def shell(self, command: str) -> str:
        return self.run("shell", command)

    def pull(self, remote: str, local: Path) -> None:
        local.parent.mkdir(parents=True, exist_ok=True)
        self.run("pull", remote, str(local), capture=False)

    def push(self, local: Path, remote: str) -> None:
        self.run("push", str(local), remote, capture=False)


def quote_shell(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def resolve_script(explicit: Path | None) -> Path:
    android_root = Path(__file__).resolve().parent
    candidates = [explicit] if explicit is not None else [
        android_root / "runtime" / "tskskinswap.js",
        android_root / "dist" / "tskskinswap.js",
    ]
    for candidate in candidates:
        if candidate is not None and candidate.is_file():
            return candidate.resolve()
    raise FileNotFoundError("Compiled Android runtime was not found; run npm run build under android/.")


def acquire_install_lock(output_root: Path) -> BinaryIO:
    output_root.mkdir(parents=True, exist_ok=True)
    handle = (output_root / ".install.lock").open("a+b")
    if handle.tell() == 0:
        handle.write(b"0")
        handle.flush()
    handle.seek(0)
    try:
        if os.name == "nt":
            import msvcrt

            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        handle.close()
        raise RuntimeError("Another Android installation is already running.") from error
    return handle


def remote_inventory(adb: Adb, paths: list[str]) -> dict[str, RemoteFile]:
    inventory: dict[str, RemoteFile] = {}
    batch_size = 40
    for offset in range(0, len(paths), batch_size):
        batch = paths[offset : offset + batch_size]
        command = (
            "for p in "
            + " ".join(quote_shell(path) for path in batch)
            + "; do if [ -f \"$p\" ]; then "
            + "s=$(stat -c '%s' \"$p\"); h=$(head -c 7 \"$p\"); "
            + "printf '%s\\t%s\\t%s\\n' \"$s\" \"$h\" \"$p\"; fi; done"
        )
        for line in adb.shell(command).splitlines():
            parts = line.split("\t", 2)
            if len(parts) == 3 and parts[0].isdigit():
                inventory[parts[2]] = RemoteFile(
                    size=int(parts[0]),
                    is_unityfs=parts[1] == "UnityFS",
                )
    return inventory


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def push_atomic(adb: Adb, local: Path, remote: str, require_unityfs: bool = False) -> None:
    temporary = remote + ".tsknew"
    adb.shell(f"rm -f {quote_shell(temporary)}")
    try:
        adb.push(local, temporary)
        remote_size = adb.shell(f"stat -c '%s' {quote_shell(temporary)}")
        if not remote_size.isdigit() or int(remote_size) != local.stat().st_size:
            raise RuntimeError(f"Device size verification failed: {remote}")
        if require_unityfs:
            header = adb.shell(f"head -c 7 {quote_shell(temporary)}")
            if header != "UnityFS":
                raise RuntimeError(f"Device UnityFS verification failed: {remote}")
        remote_hash = adb.shell(f"sha256sum {quote_shell(temporary)}").split()[0].lower()
        if remote_hash != sha256_file(local):
            raise RuntimeError(f"Device SHA-256 verification failed: {remote}")
        adb.shell(f"mv -f {quote_shell(temporary)} {quote_shell(remote)}")
    except Exception:
        try:
            adb.shell(f"rm -f {quote_shell(temporary)}")
        except Exception:
            pass
        raise


def validate_download(path: Path, target: BundleTarget) -> None:
    if target.size and path.stat().st_size != target.size:
        raise ValueError(f"size mismatch for {target.character_id}")
    with path.open("rb") as stream:
        if stream.read(7) != b"UnityFS":
            raise ValueError(f"invalid UnityFS header for {target.character_id}")


def build_mapping_document(
    package: str,
    package_version_name: str,
    catalog_hash: str,
    catalog_path: str,
    quality: str,
    edition: str,
    records: list[dict[str, object]],
) -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "packageName": package,
        "packageVersionName": package_version_name,
        "catalogSha256": catalog_hash,
        "catalogPath": catalog_path,
        "quality": quality,
        "edition": edition,
        "characters": records,
    }


def download(target: BundleTarget, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    offset = temporary.stat().st_size if temporary.is_file() else 0
    if target.size and offset >= target.size:
        temporary.unlink(missing_ok=True)
        offset = 0

    headers = {"User-Agent": "TskSkinSwap-Android/0.1"}
    if offset:
        headers["Range"] = f"bytes={offset}-"
    request = urllib.request.Request(target.url, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        if not response.geturl().startswith("https://"):
            raise ValueError("bundle download redirected to a non-HTTPS URL")
        append = offset > 0 and response.status == 206
        if append:
            content_range = response.headers.get("Content-Range", "")
            if not content_range.startswith(f"bytes {offset}-") or not content_range.endswith(
                f"/{target.size}"
            ):
                raise ValueError("bundle server returned an invalid resume range")
        mode = "ab" if append else "wb"
        if not append:
            offset = 0
        print(f"  downloading {target.character_id}: {target.size / 1048576:.1f} MiB")
        with temporary.open(mode) as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
    validate_download(temporary, target)
    os.replace(temporary, destination)


def main() -> int:
    args = parse_args()
    if not re.fullmatch(r"[A-Za-z0-9._]+", args.package):
        raise ValueError("Invalid Android package name")
    adb = Adb(args.adb)
    if adb.run("get-state") != "device":
        raise RuntimeError("No authorized Android device is connected.")
    if not adb.shell(f"pm path {args.package}").startswith("package:"):
        raise RuntimeError(f"Package is not installed: {args.package}")
    package_details = adb.shell(f"dumpsys package {args.package}")
    version_match = re.search(r"^\s*versionName=(\S+)\s*$", package_details, re.MULTILINE)
    if version_match is None:
        raise RuntimeError("Unable to read the installed Android package version")
    package_version_name = args.package_version_name or version_match.group(1)

    files_root_alias = f"/sdcard/Android/data/{args.package}/files"
    files_root = adb.shell(f"readlink -f {quote_shell(files_root_alias)}") or files_root_alias
    if not files_root.startswith("/"):
        raise RuntimeError("Unable to resolve the Android persistent data path")
    catalog_remote = f"{files_root}/com.unity.addressables/{CATALOG_NAME}"
    mod_root = f"{files_root}/tskskinswap"
    mod_bundle_root = f"{mod_root}/bundles"
    cache_root = f"{files_root}/UnityCache/Shared"
    if not args.embedded_runtime:
        script_root = f"{files_root}/frida-scripts"
        gadget_ready = adb.shell(
            f"if [ -d {quote_shell(script_root)} ]; then echo READY; fi"
        )
        if gadget_ready != "READY":
            raise RuntimeError(
                "The installed app is not a compatible Android package (APK); install the compatible Android package (APK) first."
            )

    output_root = args.output_dir.resolve()
    install_lock = acquire_install_lock(output_root)
    catalog_local = output_root / "catalog" / CATALOG_NAME
    print("Reading the current Android Addressables catalog...")
    adb.pull(catalog_remote, catalog_local)
    catalog_hash, targets = discover_targets(
        catalog_local,
        args.quality,
        args.edition,
        require_cutins=False,
    )
    if args.character_id:
        selected = set(args.character_id)
        targets = [target for target in targets if target.character_id in selected]
        missing = selected - {target.character_id for target in targets}
        if missing:
            raise RuntimeError(f"Character IDs are absent from the catalog: {', '.join(sorted(missing))}")
    if not targets:
        raise RuntimeError("No matching transform bundles were found in the Android catalog.")

    print(f"Checking UnityCache for {len(targets)} characters...")
    candidate_paths: list[str] = []
    for target in targets:
        candidate_paths.extend(
            [
                f"{cache_root}/{target.bundle_name}/{target.catalog_hash}/__data",
                f"{mod_bundle_root}/{file_name(target)}",
            ]
        )
    inventory = remote_inventory(adb, candidate_paths)
    records: list[dict[str, object]] = []
    reused_cache = 0
    reused_mod = 0
    downloaded = 0
    pushed = 0
    missing_targets: list[BundleTarget] = []

    for target in targets:
        cache_path = f"{cache_root}/{target.bundle_name}/{target.catalog_hash}/__data"
        mod_path = f"{mod_bundle_root}/{file_name(target)}"
        cache_entry = inventory.get(cache_path)
        mod_entry = inventory.get(mod_path)
        if cache_entry is not None and cache_entry.size == target.size and cache_entry.is_unityfs:
            selected_path = cache_path
            source = "unity-cache"
            reused_cache += 1
        elif mod_entry is not None and mod_entry.size == target.size and mod_entry.is_unityfs:
            selected_path = mod_path
            source = "mod-storage"
            reused_mod += 1
        else:
            selected_path = mod_path
            source = "missing" if args.dry_run else "download"
            missing_targets.append(target)

        records.append(
            {
                "characterId": target.character_id,
                "enabled": source != "missing",
                "transformBundle": selected_path,
                "transformSkeletonAsset": target.asset_path,
                "source": source,
            }
        )

    missing_bytes = sum(target.size for target in missing_targets)
    print(
        f"Cache reuse: UnityCache={reused_cache}, MOD={reused_mod}, "
        f"missing={len(missing_targets)} ({missing_bytes / 1073741824:.2f} GiB)"
    )
    if args.dry_run:
        return 0

    adb.shell(f"mkdir -p {quote_shell(mod_bundle_root)} {quote_shell(mod_root)}")
    by_character = {record["characterId"]: record for record in records}
    for target in missing_targets:
        destination = output_root / "bundles" / file_name(target)
        if destination.is_file():
            try:
                validate_download(destination, target)
                destination.with_suffix(destination.suffix + ".part").unlink(missing_ok=True)
            except Exception:
                destination.unlink()
        if not destination.is_file():
            download(target, destination)
            downloaded += 1
        remote = str(by_character[target.character_id]["transformBundle"])
        print(f"  pushing {target.character_id} to the device...")
        push_atomic(adb, destination, remote, require_unityfs=True)
        pushed += 1

    mapping_path = output_root / "mappings.json"
    mapping_path.write_text(
        json.dumps(
            build_mapping_document(
                args.package,
                package_version_name,
                catalog_hash,
                catalog_remote,
                args.quality,
                args.edition,
                records,
            ),
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
        newline="\n",
    )
    push_atomic(adb, mapping_path, f"{mod_root}/mappings.json")
    if not args.embedded_runtime:
        runtime_script = resolve_script(args.script)
        adb.push(runtime_script, f"{files_root}/frida-scripts/tskskinswap.js")
    if not args.no_restart:
        adb.shell(f"am force-stop {args.package}")
        adb.shell(f"monkey -p {args.package} -c android.intent.category.LAUNCHER 1 >/dev/null")

    for target in targets:
        destination = output_root / "bundles" / file_name(target)
        partial = destination.with_suffix(destination.suffix + ".part")
        if destination.is_file() and partial.is_file():
            validate_download(destination, target)
            partial.unlink()

    print(
        f"Installed {len(records)} mappings: UnityCache={reused_cache}, "
        f"MOD={reused_mod}, downloaded={downloaded}, pushed={pushed}."
    )
    install_lock.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit("Cancelled.")
    except Exception as error:
        raise SystemExit(f"ERROR: {error}")
