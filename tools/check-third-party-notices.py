#!/usr/bin/env python3
"""Keep shipped runtime notices aligned with pinned dependency versions."""

from hashlib import sha256
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_LICENSE_HASHES = {
    "third_party/mac/swift-protobuf-LICENSE.txt":
        "66179030bb5c3c6249c3bf7fcd498a68350c3781f9fb551777775b174b063d07",
    "third_party/android/protobuf-LICENSE.txt":
        "1358b0346fd95b645464fda29464c7273a2a28f608fd952d1978aff123bec2b5",
}


def fail(message: str) -> None:
    print(f"third-party notice check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


resolved = json.loads((ROOT / "mac/Package.resolved").read_text(encoding="utf-8"))
swift_pin = next(
    (pin for pin in resolved["pins"] if pin["identity"] == "swift-protobuf"),
    None,
)
if swift_pin is None or not swift_pin["state"].get("version"):
    fail("swift-protobuf version pin is missing")
swift_version = swift_pin["state"]["version"]

gradle = (ROOT / "android/app/build.gradle").read_text(encoding="utf-8")
protobuf_match = re.search(
    r'implementation\s+["\']com\.google\.protobuf:protobuf-javalite:([^"\']+)["\']',
    gradle,
)
if protobuf_match is None:
    fail("protobuf-javalite runtime dependency is missing")
protobuf_version = protobuf_match.group(1)

notice_versions = {
    "third_party/mac/THIRD-PARTY-NOTICES.md": ("SwiftProtobuf", swift_version),
    "third_party/android/THIRD-PARTY-NOTICES.md":
        ("Protocol Buffers Java Lite", protobuf_version),
}
for relative_path, required in notice_versions.items():
    text = (ROOT / relative_path).read_text(encoding="utf-8")
    for value in required:
        if value not in text:
            fail(f"{relative_path} does not match pinned dependency: {value}")

for relative_path, expected_hash in EXPECTED_LICENSE_HASHES.items():
    actual_hash = sha256((ROOT / relative_path).read_bytes()).hexdigest()
    if actual_hash != expected_hash:
        fail(
            f"reviewed license changed: {relative_path}; "
            "verify the upstream license and update its expected hash deliberately"
        )

print("Third-party runtime notice check passed.")
print("中文：第三方运行时版本、notice 与许可证哈希检查通过。")
