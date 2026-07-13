from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "android"))

from apk_source import SourceAsset, SupportedApk, download_asset, select_source_asset  # noqa: E402


class AndroidApkSourceTests(unittest.TestCase):
    @staticmethod
    def supported(sha256: str = "2" * 64) -> SupportedApk:
        return SupportedApk(
            release_tag="v2026.07.13",
            asset_name="Kurusuta-X.Mod_01.03.03_patched.apk",
            size=100,
            sha256=sha256,
            version_name="01.03.03",
            version_code="195",
        )

    def test_selects_standard_apk_and_ignores_legacy(self) -> None:
        release = {
            "tag_name": "v2026.07.13",
            "assets": [
                {
                    "name": "Kurusuta-X.Mod_01.03.03_patched.legacy.apk",
                    "size": 90,
                    "digest": "sha256:" + "1" * 64,
                    "browser_download_url": "https://github.com/example/legacy.apk",
                },
                {
                    "name": "Kurusuta-X.Mod_01.03.03_patched.apk",
                    "size": 100,
                    "digest": "sha256:" + "2" * 64,
                    "browser_download_url": "https://github.com/example/current.apk",
                },
            ],
        }
        asset = select_source_asset(release, self.supported())
        self.assertEqual("Kurusuta-X.Mod_01.03.03_patched.apk", asset.name)
        self.assertEqual("2" * 64, asset.sha256)

    def test_rejects_missing_digest(self) -> None:
        release = {
            "tag_name": "v1",
            "assets": [
                {
                    "name": "Kurusuta-X.Mod_01.03.03_patched.apk",
                    "size": 100,
                    "browser_download_url": "https://github.com/example/current.apk",
                }
            ],
        }
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            select_source_asset(release, self.supported())

    def test_rejects_apk_outside_full_file_allowlist(self) -> None:
        release = {
            "tag_name": "v2026.07.13",
            "assets": [
                {
                    "name": "Kurusuta-X.Mod_01.03.03_patched.apk",
                    "size": 100,
                    "digest": "sha256:" + "2" * 64,
                    "browser_download_url": "https://github.com/example/current.apk",
                }
            ],
        }
        with self.assertRaisesRegex(ValueError, "full-file fingerprint"):
            select_source_asset(release, self.supported("3" * 64))

    def test_valid_cached_apk_does_not_open_network(self) -> None:
        payload = b"apk"
        asset = SourceAsset(
            name="Kurusuta-X.Mod_01.03.03_patched.apk",
            size=len(payload),
            sha256=hashlib.sha256(payload).hexdigest(),
            url="https://github.com/example/current.apk",
            release_tag="v1",
        )
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / asset.name
            destination.write_bytes(payload)

            def fail_open(*_args: object, **_kwargs: object) -> None:
                raise AssertionError("network should not be used")

            download_asset(asset, destination, opener=fail_open)
            self.assertEqual(payload, destination.read_bytes())


if __name__ == "__main__":
    unittest.main()
