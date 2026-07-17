from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import zipfile
from dataclasses import dataclass
from pathlib import Path


SCRIPT_ENTRY = "lib/arm64-v8a/libfrida-gadget.script.so"
CONFIG_ENTRY = "lib/arm64-v8a/libfrida-gadget.config.so"
GADGET_ENTRY = "lib/arm64-v8a/libfrida-gadget.so"
EMBEDDED_MARKER = b"TSK_SKIN_SWAP_EMBEDDED"
BUNDLE_HEADER = re.compile(
    rb"\A\xf0\x9f\x93\xa6\n(?P<length>\d+) (?P<module>[^\n]+)\n\xe2\x9c\x84\n"
)
SIGNATURE_ENTRY = re.compile(
    r"\AMETA-INF/(?:MANIFEST\.MF|[^/]+\.(?:SF|RSA|DSA|EC))\Z",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class FridaBundle:
    module: str
    payload: bytes


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Embed TskSkinSwap into an existing Frida Gadget script APK."
    )
    parser.add_argument("--input-apk", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output-apk", type=Path, required=True)
    parser.add_argument("--expected-translation-sha256")
    parser.add_argument("--expected-translation-module")
    parser.add_argument("--expected-gadget-sha256")
    return parser.parse_args()


def parse_bundle(data: bytes) -> FridaBundle:
    match = BUNDLE_HEADER.match(data)
    if match is None:
        raise ValueError("file is not a supported Frida bundle")
    payload = data[match.end() :]
    declared_length = int(match.group("length"))
    if declared_length != len(payload):
        raise ValueError(
            f"Frida bundle length mismatch: declared {declared_length}, actual {len(payload)}"
        )
    try:
        module = match.group("module").decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("Frida bundle module path is not UTF-8") from error
    return FridaBundle(module=module, payload=payload)


def encode_bundle(module: str, payload: bytes) -> bytes:
    module_bytes = module.encode("utf-8")
    if b"\n" in module_bytes:
        raise ValueError("Frida bundle module path contains a newline")
    return (
        "📦\n".encode()
        + str(len(payload)).encode("ascii")
        + b" "
        + module_bytes
        + "\n✄\n".encode()
        + payload
    )


def combine_bundles(translation_data: bytes, runtime_data: bytes) -> bytes:
    translation = parse_bundle(translation_data)
    runtime = parse_bundle(runtime_data)
    if EMBEDDED_MARKER in translation.payload:
        raise ValueError("input APK already contains TskSkinSwap")

    payload = b"\n".join(
        (
            b"// TSK_SKIN_SWAP_EMBEDDED",
            b"(function () {",
            translation.payload,
            b"}).call(globalThis);",
            b"(function () {",
            runtime.payload,
            b"}).call(globalThis);",
            b"",
        )
    )
    return encode_bundle("/src/tskskinswap-combined.js", payload)


def clone_zip_info(source: zipfile.ZipInfo) -> zipfile.ZipInfo:
    clone = zipfile.ZipInfo(source.filename, source.date_time)
    clone.compress_type = source.compress_type
    clone.comment = source.comment
    clone.extra = source.extra
    clone.create_system = source.create_system
    clone.create_version = source.create_version
    clone.extract_version = source.extract_version
    clone.flag_bits = source.flag_bits & ~0x1
    clone.volume = source.volume
    clone.internal_attr = source.internal_attr
    clone.external_attr = source.external_attr
    return clone


def validate_gadget_config(data: bytes) -> None:
    try:
        document = json.loads(data.decode("utf-8"))
        interaction = document["interaction"]
    except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise ValueError("Frida Gadget configuration is invalid") from error
    if interaction.get("type") != "script" or interaction.get("path") != Path(
        SCRIPT_ENTRY
    ).name:
        raise ValueError("APK does not use the supported embedded Frida script configuration")


def patch_apk(
    input_apk: Path,
    runtime_path: Path,
    output_apk: Path,
    expected_translation_sha256: str | None = None,
    expected_translation_module: str | None = None,
    expected_gadget_sha256: str | None = None,
) -> dict[str, object]:
    input_apk = input_apk.resolve()
    runtime_path = runtime_path.resolve()
    output_apk = output_apk.resolve()
    if input_apk == output_apk:
        raise ValueError("output APK must be different from the input APK")
    if not input_apk.is_file() or not runtime_path.is_file():
        raise FileNotFoundError("input APK or Android runtime does not exist")

    runtime_data = runtime_path.read_bytes()
    parse_bundle(runtime_data)
    output_apk.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_apk.with_suffix(output_apk.suffix + ".tmp")
    temporary.unlink(missing_ok=True)

    before: dict[str, str] = {}
    after: dict[str, str] = {}
    removed_signatures: list[str] = []
    entry_count = 0
    try:
        with zipfile.ZipFile(input_apk, "r") as source:
            names = [item.filename for item in source.infolist()]
            if len(names) != len(set(names)):
                raise ValueError("input APK contains duplicate ZIP entries")
            if any(name not in names for name in (SCRIPT_ENTRY, CONFIG_ENTRY, GADGET_ENTRY)):
                raise ValueError("APK does not contain the embedded Frida Gadget files")
            validate_gadget_config(source.read(CONFIG_ENTRY))
            translation_data = source.read(SCRIPT_ENTRY)
            gadget_data = source.read(GADGET_ENTRY)
            translation_bundle = parse_bundle(translation_data)
            translation_hash = hashlib.sha256(translation_data).hexdigest()
            gadget_hash = hashlib.sha256(gadget_data).hexdigest()
            if expected_translation_sha256 and not secrets_equal_hash(
                translation_hash, expected_translation_sha256
            ):
                raise ValueError(
                    f"unsupported embedded translation script: {translation_hash}"
                )
            if (
                expected_translation_module
                and translation_bundle.module != expected_translation_module
            ):
                raise ValueError(
                    "unsupported embedded translation module: "
                    f"{translation_bundle.module}"
                )
            if expected_gadget_sha256 and not secrets_equal_hash(
                gadget_hash, expected_gadget_sha256
            ):
                raise ValueError(f"unsupported Frida Gadget: {gadget_hash}")
            combined_script = combine_bundles(translation_data, runtime_data)

            with zipfile.ZipFile(temporary, "w", allowZip64=True) as destination:
                destination.comment = source.comment
                for item in source.infolist():
                    if SIGNATURE_ENTRY.fullmatch(item.filename):
                        removed_signatures.append(item.filename)
                        continue
                    data = source.read(item.filename)
                    before[item.filename] = hashlib.sha256(data).hexdigest()
                    if item.filename == SCRIPT_ENTRY:
                        data = combined_script
                    destination.writestr(
                        clone_zip_info(item),
                        data,
                        compress_type=item.compress_type,
                        compresslevel=9,
                    )
                    after[item.filename] = hashlib.sha256(data).hexdigest()
                    entry_count += 1

        unexpected = sorted(
            name
            for name in before
            if name != SCRIPT_ENTRY and before[name] != after.get(name)
        )
        if unexpected:
            raise RuntimeError(f"APK patch changed unexpected entries: {', '.join(unexpected)}")
        if before[SCRIPT_ENTRY] == after[SCRIPT_ENTRY]:
            raise RuntimeError("combined Frida script did not change")
        os.replace(temporary, output_apk)
    finally:
        temporary.unlink(missing_ok=True)

    return {
        "inputApk": str(input_apk),
        "outputApk": str(output_apk),
        "entries": entry_count,
        "removedSignatureEntries": removed_signatures,
        "scriptEntry": SCRIPT_ENTRY,
        "translationBundleSha256": before[SCRIPT_ENTRY],
        "combinedBundleSha256": after[SCRIPT_ENTRY],
        "runtimeBundleSha256": hashlib.sha256(runtime_data).hexdigest(),
        "gadgetSha256": gadget_hash,
    }


def secrets_equal_hash(actual: str, expected: str) -> bool:
    return len(expected) == 64 and actual.lower() == expected.lower()


def main() -> int:
    args = parse_args()
    report = patch_apk(
        args.input_apk,
        args.runtime,
        args.output_apk,
        expected_translation_sha256=args.expected_translation_sha256,
        expected_translation_module=args.expected_translation_module,
        expected_gadget_sha256=args.expected_gadget_sha256,
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
