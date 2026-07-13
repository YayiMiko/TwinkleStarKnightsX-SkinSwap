from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote, urlparse


RELEASE_API = "https://api.github.com/repos/anosu/DMM-Mod/releases/tags/{tag}"
ASSET_NAME = re.compile(r"^Kurusuta-X\.Mod_[0-9.]+_patched\.apk$")
SHA256_DIGEST = re.compile(r"^sha256:([0-9a-fA-F]{64})$")
DOWNLOAD_HOSTS = {
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
}


@dataclass(frozen=True)
class SourceAsset:
    name: str
    size: int
    sha256: str
    url: str
    release_tag: str


@dataclass(frozen=True)
class SupportedApk:
    release_tag: str
    asset_name: str
    size: int
    sha256: str
    version_name: str
    version_code: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download and verify the latest compatible Android APK."
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("supported_apks.json"),
    )
    return parser.parse_args()


def require_https_host(url: str, allowed_hosts: set[str]) -> None:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in allowed_hosts:
        raise ValueError(f"unsupported download URL: {url}")


def load_supported_apk(path: Path) -> SupportedApk:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 1:
        raise ValueError("unsupported APK manifest schema")
    tag = document.get("defaultReleaseTag")
    matches = [item for item in document.get("apks", []) if item.get("releaseTag") == tag]
    if len(matches) != 1:
        raise ValueError("APK manifest must contain exactly one default release")
    item = matches[0]
    sha256 = str(item.get("sha256", "")).lower()
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ValueError("APK manifest contains an invalid SHA-256")
    size = item.get("size")
    if not isinstance(size, int) or size <= 0:
        raise ValueError("APK manifest contains an invalid size")
    version_name = str(item.get("versionName", ""))
    version_code = str(item.get("versionCode", ""))
    if not version_name or not version_code.isdigit():
        raise ValueError("APK manifest contains an invalid version")
    return SupportedApk(
        release_tag=str(tag),
        asset_name=str(item.get("assetName", "")),
        size=size,
        sha256=sha256,
        version_name=version_name,
        version_code=version_code,
    )


def select_source_asset(release: dict[str, Any], supported: SupportedApk) -> SourceAsset:
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ValueError("GitHub Release does not contain an asset list")
    matches = [asset for asset in assets if str(asset.get("name", "")) == supported.asset_name]
    if len(matches) != 1:
        raise ValueError(f"expected one standard Kurusuta APK, found {len(matches)}")

    asset = matches[0]
    digest_match = SHA256_DIGEST.fullmatch(str(asset.get("digest", "")))
    if digest_match is None:
        raise ValueError("GitHub Release APK is missing its SHA-256 digest")
    size = asset.get("size")
    if not isinstance(size, int) or size <= 0:
        raise ValueError("GitHub Release APK has an invalid size")
    url = str(asset.get("browser_download_url", ""))
    require_https_host(url, {"github.com"})
    tag = str(release.get("tag_name", ""))
    if tag != supported.release_tag:
        raise ValueError(f"unexpected GitHub Release tag: {tag}")
    if size != supported.size or digest_match.group(1).lower() != supported.sha256:
        raise ValueError("GitHub Release APK differs from the supported full-file fingerprint")
    return SourceAsset(
        name=str(asset["name"]),
        size=size,
        sha256=digest_match.group(1).lower(),
        url=url,
        release_tag=tag,
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def is_valid_download(path: Path, asset: SourceAsset) -> bool:
    return path.is_file() and path.stat().st_size == asset.size and sha256_file(path) == asset.sha256


def download_asset(
    asset: SourceAsset,
    destination: Path,
    opener: Callable[..., Any] = urllib.request.urlopen,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if is_valid_download(destination, asset):
        return
    if destination.exists():
        destination.unlink()

    temporary = destination.with_suffix(destination.suffix + ".part")
    offset = temporary.stat().st_size if temporary.is_file() else 0
    if offset >= asset.size:
        temporary.unlink(missing_ok=True)
        offset = 0

    headers = {"User-Agent": "TskSkinSwap-Android/0.2"}
    if offset:
        headers["Range"] = f"bytes={offset}-"
    request = urllib.request.Request(asset.url, headers=headers)
    with opener(request, timeout=60) as response:
        require_https_host(response.geturl(), DOWNLOAD_HOSTS)
        append = offset > 0 and response.status == 206
        if append:
            expected_prefix = f"bytes {offset}-"
            content_range = response.headers.get("Content-Range", "")
            if not content_range.startswith(expected_prefix) or not content_range.endswith(
                f"/{asset.size}"
            ):
                raise ValueError("APK server returned an invalid resume range")
        mode = "ab" if append else "wb"
        with temporary.open(mode) as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)

    if not is_valid_download(temporary, asset):
        raise ValueError("downloaded APK failed its size or SHA-256 check")
    os.replace(temporary, destination)


def fetch_release(tag: str) -> dict[str, Any]:
    request = urllib.request.Request(
        RELEASE_API.format(tag=quote(tag, safe="")),
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "TskSkinSwap-Android/0.2",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        require_https_host(response.geturl(), {"api.github.com"})
        return json.load(response)


def main() -> int:
    args = parse_args()
    supported = load_supported_apk(args.manifest.resolve())
    asset = select_source_asset(fetch_release(supported.release_tag), supported)
    destination = args.output_dir.resolve() / asset.name
    print(f"Compatible APK: {asset.name} ({asset.release_tag})", file=sys.stderr)
    if not is_valid_download(destination, asset):
        print(f"Downloading {asset.size / 1048576:.1f} MiB...", file=sys.stderr)
    download_asset(asset, destination)
    metadata = {
        "schemaVersion": 1,
        "releaseTag": asset.release_tag,
        "assetName": asset.name,
        "size": asset.size,
        "sha256": asset.sha256,
        "versionName": supported.version_name,
        "versionCode": supported.version_code,
        "sourceUrl": asset.url,
    }
    metadata_path = args.output_dir.resolve() / "source-apk.json"
    temporary_metadata = metadata_path.with_suffix(".json.tmp")
    temporary_metadata.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    os.replace(temporary_metadata, metadata_path)
    print(destination)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit("Cancelled.")
    except Exception as error:
        raise SystemExit(f"ERROR: {error}")
