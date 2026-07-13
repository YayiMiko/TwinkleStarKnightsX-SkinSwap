from __future__ import annotations

import hashlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "android"))

import installer as android_installer  # noqa: E402
from catalog_downloader import BundleTarget  # noqa: E402


class FakeAdb:
    def __init__(self, payload: bytes = b"") -> None:
        self.payload = payload
        self.commands: list[str] = []
        self.pushes: list[tuple[Path, str]] = []

    def shell(self, command: str) -> str:
        self.commands.append(command)
        if command.startswith("for p in"):
            return "7\tUnityFS\t/valid\n7\tInvalid\t/invalid"
        if command.startswith("stat -c"):
            return str(len(self.payload))
        if command.startswith("head -c"):
            return self.payload[:7].decode("ascii")
        if command.startswith("sha256sum"):
            return hashlib.sha256(self.payload).hexdigest() + "  remote"
        return ""

    def push(self, local: Path, remote: str) -> None:
        self.pushes.append((local, remote))


class FakeResponse(io.BytesIO):
    def __init__(self, payload: bytes, status: int, url: str, headers: dict[str, str]) -> None:
        super().__init__(payload)
        self.status = status
        self.url = url
        self.headers = headers

    def geturl(self) -> str:
        return self.url

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()


def target(size: int) -> BundleTarget:
    return BundleTarget(
        kind="transform",
        character_id="1001001",
        edition="adult",
        asset_path="asset",
        url="https://example.invalid/bundle",
        size=size,
        catalog_hash="hash",
        crc=0,
        bundle_name="bundle",
    )


class AndroidInstallerTests(unittest.TestCase):
    def test_inventory_requires_unityfs_header(self) -> None:
        inventory = android_installer.remote_inventory(FakeAdb(), ["/valid", "/invalid"])
        self.assertTrue(inventory["/valid"].is_unityfs)
        self.assertFalse(inventory["/invalid"].is_unityfs)

    def test_atomic_push_verifies_before_rename(self) -> None:
        payload = b"UnityFS-content"
        adb = FakeAdb(payload)
        with tempfile.TemporaryDirectory() as directory:
            local = Path(directory) / "bundle"
            local.write_bytes(payload)
            android_installer.push_atomic(adb, local, "/remote/bundle", require_unityfs=True)
        self.assertEqual("/remote/bundle.tsknew", adb.pushes[0][1])
        self.assertTrue(any(command.startswith("mv -f") for command in adb.commands))

    def test_mapping_contains_runtime_fingerprints(self) -> None:
        document = android_installer.build_mapping_document(
            "package",
            "01.03.03",
            "catalog-sha256",
            "/catalog.json",
            "HighQuality",
            "adult",
            [],
        )
        self.assertEqual(2, document["schemaVersion"])
        self.assertEqual("01.03.03", document["packageVersionName"])
        self.assertEqual("catalog-sha256", document["catalogSha256"])

    def test_download_rejects_non_https_redirect(self) -> None:
        payload = b"UnityFS-content"
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "bundle"
            with patch(
                "installer.urllib.request.urlopen",
                return_value=FakeResponse(payload, 200, "http://example.invalid/bundle", {}),
            ):
                with self.assertRaisesRegex(ValueError, "non-HTTPS"):
                    android_installer.download(target(len(payload)), destination)


if __name__ == "__main__":
    unittest.main()
