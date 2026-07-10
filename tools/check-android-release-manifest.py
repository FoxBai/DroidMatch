#!/usr/bin/env python3
"""Verify privacy and exported-component boundaries in a merged release manifest."""

import argparse
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
EXPECTED_PERMISSIONS = {
    "android.permission.INTERNET",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
}
PRODUCT_ACTIVITY = "app.droidmatch.m1.DroidMatchActivity"
PRODUCT_SERVICE = "app.droidmatch.m1.ForegroundConnectionService"


def fail(message: str) -> None:
    print(f"Android release manifest check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


parser = argparse.ArgumentParser()
parser.add_argument("manifest", type=Path)
args = parser.parse_args()
if not args.manifest.is_file():
    fail(f"manifest does not exist: {args.manifest}")

root = ET.parse(args.manifest).getroot()
if root.get("package") != "app.droidmatch":
    fail(f"unexpected package: {root.get('package')}")

permissions = {
    element.get(ANDROID + "name")
    for element in root.findall("uses-permission")
}
if permissions != EXPECTED_PERMISSIONS:
    fail(
        "permission allowlist changed: "
        f"missing={sorted(EXPECTED_PERMISSIONS - permissions)} "
        f"unexpected={sorted(permissions - EXPECTED_PERMISSIONS)}"
    )

legacy_media = next(
    element
    for element in root.findall("uses-permission")
    if element.get(ANDROID + "name") == "android.permission.READ_EXTERNAL_STORAGE"
)
if legacy_media.get(ANDROID + "maxSdkVersion") != "32":
    fail("READ_EXTERNAL_STORAGE must remain capped at API 32")

application = root.find("application")
if application is None:
    fail("application element is missing")
if application.get(ANDROID + "name") != "app.droidmatch.m1.DroidMatchApplication":
    fail("unexpected Application class")
if application.get(ANDROID + "allowBackup") != "false":
    fail("allowBackup must be false")
if application.get(ANDROID + "debuggable") == "true":
    fail("release application must not be debuggable")
if application.get(ANDROID + "fullBackupContent") != "@xml/backup_rules":
    fail("legacy backup exclusion rules are missing")
if application.get(ANDROID + "dataExtractionRules") != "@xml/data_extraction_rules":
    fail("Android 12+ extraction rules are missing")

exported_components = []
for component_type in ("activity", "activity-alias", "service", "receiver", "provider"):
    for component in application.findall(component_type):
        if component.get(ANDROID + "exported") == "true":
            exported_components.append((component_type, component.get(ANDROID + "name")))
if exported_components != [("activity", PRODUCT_ACTIVITY)]:
    fail(f"exported component boundary changed: {exported_components}")

services = application.findall("service")
if len(services) != 1 or services[0].get(ANDROID + "name") != PRODUCT_SERVICE:
    fail("release must contain exactly the product connection service")
if services[0].get(ANDROID + "exported") != "false":
    fail("product connection service must be non-exported")
if services[0].get(ANDROID + "foregroundServiceType") != "dataSync":
    fail("ADB endpoint service must retain the reviewed dataSync type")

print("Android release manifest check passed.")
print("中文：Android release 权限、备份与导出组件边界检查通过。")
