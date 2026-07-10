#!/usr/bin/env python3
"""Verify the assembled macOS product boundary from bundle artifacts."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import sys

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


parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--sandboxed", action="store_true")
args = parser.parse_args()
app = args.app
contents = app / "Contents"
if not app.is_dir() or app.suffix != ".app":
    fail(f"not an App bundle: {app}")

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

macos = contents / "MacOS"
executables = sorted(path.name for path in macos.iterdir() if path.is_file()) if macos.is_dir() else []
if executables != ["DroidMatch"] or not (macos / "DroidMatch").stat().st_mode & 0o111:
    fail(f"product bundle must contain only the DroidMatch executable: {executables}")

resources = contents / "Resources"
resource_bundle = resources / "DroidMatchMac_DroidMatchApp.bundle"
required_resources = (
    resources / "DroidMatch.icns",
    resource_bundle / "Info.plist",
    resource_bundle / "en.lproj" / "Localizable.strings",
    resource_bundle / "zh-hans.lproj" / "Localizable.strings",
)
for resource in required_resources:
    if not resource.is_file() or resource.stat().st_size == 0:
        fail(f"required product resource is missing or empty: {resource.relative_to(app)}")

verification = subprocess.run(
    ["codesign", "--verify", "--deep", "--strict", str(app)],
    capture_output=True,
    text=True,
)
if verification.returncode != 0:
    fail(f"codesign verification failed: {verification.stderr.strip()}")
entitlements_result = subprocess.run(
    ["codesign", "-d", "--entitlements", ":-", str(app)],
    capture_output=True,
)
if entitlements_result.returncode != 0:
    fail("could not read bundle entitlements")
entitlements = (
    plistlib.loads(entitlements_result.stdout)
    if entitlements_result.stdout.strip()
    else {}
)

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
    if subprocess.run([str(adb), "version"], capture_output=True).returncode != 0:
        fail("embedded adb is not runnable")
else:
    if entitlements:
        fail(f"ordinary local bundle unexpectedly has entitlements: {entitlements}")
    if platform_tools.exists():
        fail("ordinary local bundle must not embed platform-tools")

print(f"Mac App bundle check passed: {app}")
print("中文：Mac 产品 bundle、资源、签名与 entitlement 边界检查通过。")
