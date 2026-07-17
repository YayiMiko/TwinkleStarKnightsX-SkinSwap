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


RELEASES_API = "https://api.github.com/repos/{repository}/releases?per_page=100"
TRUSTED_REPOSITORY = "anosu/DMM-Mod"
ASSET_NAME = re.compile(
    r"^Kurusuta-X\.Mod_(?P<version>[0-9]+(?:\.[0-9]+)*)_patched\.apk$"
)
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
    version_name: str


@dataclass(frozen=True)
class SourcePolicy:
    repository: str


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
    parser.add_argument("--minimum-version-name")
    parser.add_argument("--required-version-name")
    return parser.parse_args()


def require_https_host(url: str, allowed_hosts: set[str]) -> None:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in allowed_hosts:
        raise ValueError(f"unsupported download URL: {url}")


def load_source_policy(path: Path) -> SourcePolicy:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 2:
        raise ValueError("unsupported APK source policy schema")
    repository = str(document.get("sourceRepository", ""))
    if repository != TRUSTED_REPOSITORY:
        raise ValueError("APK source policy contains an untrusted repository")
    return SourcePolicy(repository=repository)


def version_key(version: str) -> tuple[int, ...]:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise ValueError(f"invalid APK version: {version}")
    return tuple(int(part) for part in version.split("."))


def source_asset_from_release(
    release: dict[str, Any], asset: dict[str, Any]
) -> SourceAsset:
    name = str(asset.get("name", ""))
    name_match = ASSET_NAME.fullmatch(name)
    if name_match is None:
        raise ValueError(f"unexpected Kurusuta APK asset name: {name}")
    digest_match = SHA256_DIGEST.fullmatch(str(asset.get("digest", "")))
    if digest_match is None:
        raise ValueError(f"GitHub Release APK is missing its SHA-256 digest: {name}")
    size = asset.get("size")
    if not isinstance(size, int) or size <= 0:
        raise ValueError(f"GitHub Release APK has an invalid size: {name}")
    url = str(asset.get("browser_download_url", ""))
    require_https_host(url, {"github.com"})
    tag = str(release.get("tag_name", ""))
    if not tag:
        raise ValueError("GitHub Release tag is missing")
    return SourceAsset(
        name=name,
        size=size,
        sha256=digest_match.group(1).lower(),
        url=url,
        release_tag=tag,
        version_name=name_match.group("version"),
    )


def select_source_asset(
    releases: list[dict[str, Any]],
    minimum_version_name: str | None = None,
    required_version_name: str | None = None,
) -> SourceAsset:
    candidates: list[tuple[tuple[int, ...], dict[str, Any], dict[str, Any]]] = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        assets = release.get("assets")
        if not isinstance(assets, list):
            continue
        for asset in assets:
            match = ASSET_NAME.fullmatch(str(asset.get("name", "")))
            if match:
                candidates.append((version_key(match.group("version")), release, asset))
    if not candidates:
        raise ValueError("no standard Kurusuta APK was found in the trusted repository")

    if required_version_name:
        required_key = version_key(required_version_name)
        candidates = [candidate for candidate in candidates if candidate[0] == required_key]
        if not candidates:
            raise ValueError(
                "anosu/DMM-Mod does not contain the installed game version "
                f"({required_version_name})"
            )
    _, latest_release, latest_asset = max(candidates, key=lambda candidate: candidate[0])
    latest = source_asset_from_release(latest_release, latest_asset)
    if minimum_version_name and version_key(latest.version_name) < version_key(
        minimum_version_name
    ):
        raise ValueError(
            "the installed game is newer than the latest APK in anosu/DMM-Mod "
            f"({minimum_version_name} > {latest.version_name}); wait for their new package"
        )
    return latest


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

    headers = {"User-Agent": "TskSkinSwap-Android/0.3"}
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
        raise ValueError("downloaded APK differs from GitHub's published SHA-256 or size")
    os.replace(temporary, destination)


def fetch_releases(repository: str) -> list[dict[str, Any]]:
    if repository != TRUSTED_REPOSITORY:
        raise ValueError("untrusted APK source repository")
    request = urllib.request.Request(
        RELEASES_API.format(repository=quote(repository, safe="/")),
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "TskSkinSwap-Android/0.3",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        require_https_host(response.geturl(), {"api.github.com"})
        document = json.load(response)
    if not isinstance(document, list):
        raise ValueError("GitHub Releases API returned an invalid document")
    return document


def main() -> int:
    args = parse_args()
    if args.minimum_version_name and args.required_version_name:
        raise ValueError("minimum and required APK versions cannot be combined")
    policy = load_source_policy(args.manifest.resolve())
    print("Checking anosu/DMM-Mod for the latest Kurusuta APK...", file=sys.stderr)
    asset = select_source_asset(
        fetch_releases(policy.repository),
        args.minimum_version_name,
        args.required_version_name,
    )
    destination = args.output_dir.resolve() / asset.name
    print(f"Compatible APK: {asset.name} ({asset.release_tag})", file=sys.stderr)
    if not is_valid_download(destination, asset):
        print(f"Downloading {asset.size / 1048576:.1f} MiB...", file=sys.stderr)
    download_asset(asset, destination)
    metadata = {
        "schemaVersion": 2,
        "sourceRepository": policy.repository,
        "releaseTag": asset.release_tag,
        "assetName": asset.name,
        "size": asset.size,
        "sha256": asset.sha256,
        "versionName": asset.version_name,
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
