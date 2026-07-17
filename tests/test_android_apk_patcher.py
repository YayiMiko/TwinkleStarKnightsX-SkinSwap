from __future__ import annotations

import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "android"))

from apk_patcher import (  # noqa: E402
    CONFIG_ENTRY,
    EMBEDDED_MARKER,
    GADGET_ENTRY,
    SCRIPT_ENTRY,
    combine_bundles,
    encode_bundle,
    parse_bundle,
    patch_apk,
)


class AndroidApkPatcherTests(unittest.TestCase):
    def test_bundle_round_trip(self) -> None:
        encoded = encode_bundle("/src/example.js", b"globalThis.example = true;\n")
        decoded = parse_bundle(encoded)
        self.assertEqual("/src/example.js", decoded.module)
        self.assertEqual(b"globalThis.example = true;\n", decoded.payload)

    def test_bundle_rejects_wrong_length(self) -> None:
        with self.assertRaisesRegex(ValueError, "length mismatch"):
            parse_bundle("📦\n2 /src/example.js\n✄\nabc".encode())

    def test_combined_bundle_isolates_both_scripts(self) -> None:
        translation = encode_bundle("/src/translation.js", b"var shared = 'translation';")
        runtime = encode_bundle("/src/runtime.js", b"var shared = 'runtime';")
        combined = parse_bundle(combine_bundles(translation, runtime))
        self.assertEqual("/src/tskskinswap-combined.js", combined.module)
        self.assertIn(EMBEDDED_MARKER, combined.payload)
        self.assertEqual(2, combined.payload.count(b"(function () {"))
        self.assertIn(b"var shared = 'translation';", combined.payload)
        self.assertIn(b"var shared = 'runtime';", combined.payload)

    def test_patch_changes_only_script_and_removes_v1_signature(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.apk"
            runtime = root / "runtime.js"
            output = root / "output.apk"
            translation_data = encode_bundle("/src/translation.js", b"translation();")
            runtime.write_bytes(encode_bundle("/src/runtime.js", b"runtime();"))
            config = json.dumps(
                {
                    "interaction": {
                        "type": "script",
                        "path": Path(SCRIPT_ENTRY).name,
                        "on_load": "resume",
                    }
                }
            ).encode()
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(CONFIG_ENTRY, config)
                archive.writestr(SCRIPT_ENTRY, translation_data)
                archive.writestr(GADGET_ENTRY, b"gadget")
                archive.writestr("assets/unchanged.bin", b"unchanged")
                archive.writestr("META-INF/CERT.SF", b"old signature")

            report = patch_apk(source, runtime, output)

            with zipfile.ZipFile(output) as archive:
                self.assertEqual(config, archive.read(CONFIG_ENTRY))
                self.assertEqual(b"unchanged", archive.read("assets/unchanged.bin"))
                self.assertNotIn("META-INF/CERT.SF", archive.namelist())
                patched = parse_bundle(archive.read(SCRIPT_ENTRY))
                self.assertIn(EMBEDDED_MARKER, patched.payload)
            self.assertEqual(["META-INF/CERT.SF"], report["removedSignatureEntries"])

    def test_patch_rejects_unexpected_translation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.apk"
            runtime = root / "runtime.js"
            output = root / "output.apk"
            runtime.write_bytes(encode_bundle("/src/runtime.js", b"runtime();"))
            config = json.dumps(
                {
                    "interaction": {
                        "type": "script",
                        "path": Path(SCRIPT_ENTRY).name,
                    }
                }
            ).encode()
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(CONFIG_ENTRY, config)
                archive.writestr(
                    SCRIPT_ENTRY,
                    encode_bundle("/src/translation.js", b"translation();"),
                )

    def test_patch_rejects_unexpected_translation_module(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.apk"
            runtime = root / "runtime.js"
            output = root / "output.apk"
            runtime.write_bytes(encode_bundle("/src/runtime.js", b"runtime();"))
            config = json.dumps(
                {
                    "interaction": {
                        "type": "script",
                        "path": Path(SCRIPT_ENTRY).name,
                    }
                }
            ).encode()
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(CONFIG_ENTRY, config)
                archive.writestr(
                    SCRIPT_ENTRY,
                    encode_bundle("/src/unexpected.js", b"translation();"),
                )
                archive.writestr(GADGET_ENTRY, b"gadget")

            with self.assertRaisesRegex(ValueError, "translation module"):
                patch_apk(
                    source,
                    runtime,
                    output,
                    expected_translation_module="/src/translation.js",
                )
                archive.writestr(GADGET_ENTRY, b"gadget")

            with self.assertRaisesRegex(ValueError, "unsupported embedded translation"):
                patch_apk(
                    source,
                    runtime,
                    output,
                    expected_translation_sha256="0" * 64,
                )

    def test_patch_rejects_already_patched_input(self) -> None:
        translation = encode_bundle("/src/translation.js", EMBEDDED_MARKER)
        runtime = encode_bundle("/src/runtime.js", b"runtime();")
        with self.assertRaisesRegex(ValueError, "already contains"):
            combine_bundles(translation, runtime)


if __name__ == "__main__":
    unittest.main()
