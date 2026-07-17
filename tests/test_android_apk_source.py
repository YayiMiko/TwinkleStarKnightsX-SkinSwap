from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "android"))

from apk_source import SourceAsset, download_asset, select_source_asset  # noqa: E402


def apk_asset(version: str, digest: str = "2" * 64) -> dict[str, object]:
    return {
        "name": f"Kurusuta-X.Mod_{version}_patched.apk",
        "size": 100,
        "digest": "sha256:" + digest,
        "browser_download_url": "https://github.com/example/current.apk",
    }


class AndroidApkSourceTests(unittest.TestCase):
    def test_selects_latest_standard_apk_and_ignores_legacy(self) -> None:
        releases = [
            {
                "tag_name": "v2026.07.13",
                "draft": False,
                "prerelease": False,
                "assets": [
                    {
                        "name": "Kurusuta-X.Mod_01.03.03_patched.legacy.apk",
                        "size": 90,
                        "digest": "sha256:" + "1" * 64,
                        "browser_download_url": "https://github.com/example/legacy.apk",
                    },
                    apk_asset("01.03.03"),
                ],
            },
            {
                "tag_name": "v2026.07.17",
                "draft": False,
                "prerelease": False,
                "assets": [apk_asset("01.03.04", "3" * 64)],
            },
        ]
        asset = select_source_asset(releases)
        self.assertEqual("Kurusuta-X.Mod_01.03.04_patched.apk", asset.name)
        self.assertEqual("3" * 64, asset.sha256)
        self.assertEqual("01.03.04", asset.version_name)

    def test_rejects_missing_digest(self) -> None:
        asset = apk_asset("01.03.04")
        del asset["digest"]
        releases = [{"tag_name": "v1", "assets": [asset]}]
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            select_source_asset(releases)

    def test_rejects_downgrade_below_installed_version(self) -> None:
        releases = [{"tag_name": "v1", "assets": [apk_asset("01.03.03")]}]
        with self.assertRaisesRegex(ValueError, "installed game is newer"):
            select_source_asset(releases, "01.03.04")

    def test_selects_exact_installed_version_for_restore(self) -> None:
        releases = [
            {"tag_name": "new", "assets": [apk_asset("01.03.04")]},
            {"tag_name": "old", "assets": [apk_asset("01.03.03")]},
        ]
        asset = select_source_asset(
            releases, required_version_name="01.03.03"
        )
        self.assertEqual("01.03.03", asset.version_name)

    def test_valid_cached_apk_does_not_open_network(self) -> None:
        payload = b"apk"
        asset = SourceAsset(
            name="Kurusuta-X.Mod_01.03.04_patched.apk",
            size=len(payload),
            sha256=hashlib.sha256(payload).hexdigest(),
            url="https://github.com/example/current.apk",
            release_tag="v1",
            version_name="01.03.04",
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
