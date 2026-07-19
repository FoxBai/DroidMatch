#!/usr/bin/env python3
"""Verify the assembled macOS product boundary from bundle artifacts."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import unicodedata
from typing import Optional
from urllib.parse import urlsplit
from xml.parsers.expat import ExpatError

EXPECTED_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.device.usb": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.network.client": True,
    "com.apple.security.network.server": True,
}


def fail(message: str) -> None:
    print(f"Mac App bundle check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_static_tree(root: Path) -> None:
    if root.is_symlink():
        fail("App bundle must not be a symbolic link")
    root_metadata = read_node_metadata(root)
    if not stat.S_ISDIR(root_metadata.st_mode):
        fail("App bundle must be a directory")
    validate_node_metadata(root, root, root_metadata)
    for current_root, directories, files in os.walk(
        root,
        followlinks=False,
        onerror=lambda _: fail("App bundle tree could not be inspected"),
    ):
        current = Path(current_root)
        for name in directories + files:
            candidate = current / name
            if candidate.is_symlink():
                fail(
                    "App bundle must not contain symbolic links: "
                    f"{candidate.relative_to(root)}"
                )
            validate_node_metadata(root, candidate, read_node_metadata(candidate))


def read_node_metadata(path: Path) -> os.stat_result:
    try:
        return path.lstat()
    except OSError:
        fail("App bundle tree changed or could not be inspected")


def validate_node_metadata(root: Path, path: Path, metadata: os.stat_result) -> None:
    relative = path.relative_to(root)
    label = "." if str(relative) == "." else str(relative)
    if stat.S_ISREG(metadata.st_mode):
        if metadata.st_nlink != 1:
            fail(f"App bundle files must have exactly one link: {label}")
        if metadata.st_mode & 0o400 == 0:
            fail(f"App bundle files must be owner-readable: {label}")
    elif stat.S_ISDIR(metadata.st_mode):
        if metadata.st_mode & 0o500 != 0o500:
            fail(f"App bundle directories must be owner-readable/traversable: {label}")
    else:
        fail(f"App bundle contains an unsupported filesystem node: {label}")
    if metadata.st_mode & 0o7000:
        fail(f"App bundle nodes must not have special permission bits: {label}")
    if metadata.st_mode & 0o022:
        fail(f"App bundle nodes must not be group/world writable: {label}")


def strict_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def valid_device_identity(value: object) -> bool:
    if type(value) is not str:
        return False
    normalized = unicodedata.normalize("NFC", value).strip()
    return bool(normalized) and len(normalized) <= 512 and all(
        unicodedata.category(character) not in {"Cc", "Cf", "Cs"}
        for character in normalized
    )


def valid_display_text(value: object) -> bool:
    if type(value) is not str:
        return False
    return any(
        not character.isspace()
        and unicodedata.category(character) not in {"Cc", "Cf", "Cs"}
        for character in unicodedata.normalize("NFC", value)
    )


def normalized_language_tag(value: object) -> Optional[str]:
    if type(value) is not str:
        return None
    tag = value.strip().replace("_", "-")
    try:
        tag_bytes = tag.encode("ascii")
    except UnicodeEncodeError:
        return None
    components = tag.split("-")
    if not 1 <= len(components) <= 8 or not 1 <= len(tag_bytes) <= 64:
        return None
    if not re.fullmatch(r"[A-Za-z]{2,3}", components[0]) or any(
        re.fullmatch(r"[A-Za-z0-9]{2,8}", component) is None
        for component in components[1:]
    ):
        return None
    return tag.lower()


def validate_marketing_alias_data(path: Path) -> None:
    if path.stat().st_size > 128 * 1_024:
        fail("device marketing-name data exceeds its byte limit")
    try:
        value = json.loads(path.read_bytes(), object_pairs_hook=strict_json_object)
    except (OSError, UnicodeDecodeError, ValueError, RecursionError):
        fail("device marketing-name data is not valid JSON")
    if type(value) is not dict or set(value) != {"schemaVersion", "records"}:
        fail("device marketing-name data has an unsupported root shape")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        fail("device marketing-name data has an unsupported schema version")
    records = value["records"]
    if type(records) is not list or len(records) > 128:
        fail("device marketing-name data has an invalid record collection")
    required = {"model", "device", "canonicalName", "localizedNames", "sourceURL"}
    allowed = required | {"product"}
    for record in records:
        if type(record) is not dict or not required.issubset(record) or not set(record) <= allowed:
            fail("device marketing-name data contains an invalid record shape")
        if not valid_device_identity(record["model"]) or not valid_device_identity(record["device"]):
            fail("device marketing-name data contains an invalid identity field")
        if "product" in record and not valid_device_identity(record["product"]):
            fail("device marketing-name data contains an invalid product field")
        if not valid_display_text(record["canonicalName"]):
            fail("device marketing-name data contains an invalid canonical name")
        names = record["localizedNames"]
        if type(names) is not dict or len(names) > 16 or any(
            type(tag) is not str or type(name) is not str for tag, name in names.items()
        ):
            fail("device marketing-name data contains invalid localized names")
        normalized_tags = [normalized_language_tag(tag) for tag in names]
        if None in normalized_tags or len(set(normalized_tags)) != len(normalized_tags):
            fail("device marketing-name data contains invalid language tags")
        if any(not valid_display_text(name) for name in names.values()):
            fail("device marketing-name data contains an invalid localized name")
        source = record["sourceURL"]
        if type(source) is not str:
            fail("device marketing-name data contains an invalid source URL")
        try:
            source_parts = urlsplit(source)
            source_bytes = source.encode("utf-8")
        except (UnicodeEncodeError, ValueError):
            fail("device marketing-name data contains an invalid source URL")
        if (
            len(source_bytes) > 2_048
            or source_parts.scheme.lower() != "https"
            or not source_parts.hostname
            or source_parts.username is not None
            or source_parts.password is not None
            or source_parts.fragment
        ):
            fail("device marketing-name data contains an unsafe source URL")


parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--sandboxed", action="store_true")
parser.add_argument("--defer-adb-execution", action="store_true")
args = parser.parse_args()
app = args.app
if args.defer_adb_execution and not args.sandboxed:
    fail("adb execution can be deferred only for a sandboxed candidate")
contents = app / "Contents"
if not app.is_dir() or app.suffix != ".app":
    fail(f"not an App bundle: {app}")
validate_static_tree(app)

info_path = contents / "Info.plist"
try:
    with info_path.open("rb") as info_file:
        info = plistlib.load(info_file)
except (OSError, plistlib.InvalidFileException) as error:
    fail(f"invalid Info.plist: {error}")

expected_info = {
    "CFBundleIdentifier": "app.droidmatch.mac",
    "CFBundleExecutable": "DroidMatch",
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": "13.0",
    "ITSAppUsesNonExemptEncryption": False,
}
for key, expected in expected_info.items():
    if info.get(key) != expected:
        fail(f"unexpected {key}: {info.get(key)!r}")
if set(info.get("CFBundleLocalizations", [])) != {"en", "zh-Hans"}:
    fail("bundle localizations must be exactly en and zh-Hans")
source_revision = info.get("DroidMatchSourceRevision")
if not isinstance(source_revision, str) or re.fullmatch(r"[0-9a-f]{40}", source_revision) is None:
    fail("bundle must embed one full lowercase Git source revision")
if not isinstance(info.get("DroidMatchSourceDirty"), bool):
    fail("bundle must embed a boolean source-dirty provenance field")
if info.get("DroidMatchBuildConfiguration") not in {"debug", "release"}:
    fail("bundle must embed its debug or release build configuration")

macos = contents / "MacOS"
executables = sorted(path.name for path in macos.iterdir() if path.is_file()) if macos.is_dir() else []
if executables != ["DroidMatch"] or not (macos / "DroidMatch").stat().st_mode & 0o111:
    fail(f"product bundle must contain only the DroidMatch executable: {executables}")

resources = contents / "Resources"
resource_bundle = resources / "DroidMatchMac_DroidMatchApp.bundle"
protobuf_bundle = resources / "SwiftProtobuf_SwiftProtobuf.bundle"
app_privacy_manifest = resources / "PrivacyInfo.xcprivacy"
protobuf_privacy_manifest = protobuf_bundle / "PrivacyInfo.xcprivacy"
marketing_alias_data = resources / "device-marketing-name-aliases.json"
required_resources = (
    resources / "DroidMatch.icns",
    resource_bundle / "Info.plist",
    resource_bundle / "en.lproj" / "Localizable.strings",
    resource_bundle / "zh-hans.lproj" / "Localizable.strings",
    app_privacy_manifest,
    protobuf_privacy_manifest,
    marketing_alias_data,
    resources / "Legal" / "THIRD-PARTY-NOTICES.md",
    resources / "Legal" / "swift-protobuf-LICENSE.txt",
)
for resource in required_resources:
    if not resource.is_file() or resource.stat().st_size == 0:
        fail(f"required product resource is missing or empty: {resource.relative_to(app)}")
validate_marketing_alias_data(marketing_alias_data)
notices = (resources / "Legal" / "THIRD-PARTY-NOTICES.md").read_text(encoding="utf-8")
for required_notice in ("SwiftProtobuf", "1.38.1", "Apache License 2.0"):
    if required_notice not in notices:
        fail(f"third-party notices are missing: {required_notice}")
try:
    with app_privacy_manifest.open("rb") as privacy_file:
        app_privacy = plistlib.load(privacy_file)
except (OSError, plistlib.InvalidFileException) as error:
    fail(f"invalid DroidMatch privacy manifest: {error}")
expected_app_privacy = {
    "NSPrivacyTracking": False,
    "NSPrivacyTrackingDomains": [],
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyAccessedAPITypes": [],
}
if app_privacy != expected_app_privacy:
    fail(f"DroidMatch privacy declaration changed: {app_privacy}")
try:
    with protobuf_privacy_manifest.open("rb") as privacy_file:
        protobuf_privacy = plistlib.load(privacy_file)
except (OSError, plistlib.InvalidFileException) as error:
    fail(f"invalid SwiftProtobuf privacy manifest: {error}")
if protobuf_privacy.get("NSPrivacyTracking") is not False:
    fail("SwiftProtobuf privacy manifest must explicitly declare no tracking")

verification = subprocess.run(
    ["codesign", "--verify", "--deep", "--strict", str(app)],
    capture_output=True,
    text=True,
)
if verification.returncode != 0:
    fail(f"codesign verification failed: {verification.stderr.strip()}")
entitlements_result = subprocess.run(
    ["codesign", "-d", "--entitlements", "-", "--xml", str(app)],
    capture_output=True,
)
if entitlements_result.returncode != 0:
    fail("could not read bundle entitlements")
try:
    entitlements = (
        plistlib.loads(entitlements_result.stdout, fmt=plistlib.FMT_XML)
        if entitlements_result.stdout.strip()
        else {}
    )
except (plistlib.InvalidFileException, ExpatError, TypeError, ValueError):
    fail("bundle entitlements are not a valid XML property list")

platform_tools = resources / "platform-tools"
if args.sandboxed:
    if entitlements != EXPECTED_ENTITLEMENTS:
        fail(f"sandbox entitlement allowlist changed: {entitlements}")
    adb = platform_tools / "adb"
    notice = platform_tools / "NOTICE.txt"
    if not adb.is_file() or not adb.stat().st_mode & 0o111:
        fail("sandbox bundle is missing executable embedded adb")
    if not notice.is_file() or notice.stat().st_size == 0:
        fail("sandbox bundle is missing platform-tools NOTICE.txt")
    adb_verification = subprocess.run(
        ["codesign", "--verify", "--strict", str(adb)],
        capture_output=True,
        text=True,
    )
    if adb_verification.returncode != 0:
        fail(f"embedded adb signature is invalid: {adb_verification.stderr.strip()}")
    if (not args.defer_adb_execution
            and subprocess.run([str(adb), "version"], capture_output=True).returncode != 0):
        fail("embedded adb is not runnable")
else:
    if entitlements:
        fail(f"ordinary local bundle unexpectedly has entitlements: {entitlements}")
    if platform_tools.exists():
        fail("ordinary local bundle must not embed platform-tools")

print(f"Mac App bundle check passed: {app}")
print("中文：Mac 产品 bundle、资源、签名与 entitlement 边界检查通过。")
