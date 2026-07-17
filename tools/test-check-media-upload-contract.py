#!/usr/bin/env python3
"""Offline regressions for the cross-platform media upload contract checker."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER_PATH = ROOT / "tools/check-media-upload-contract.py"
SPEC = importlib.util.spec_from_file_location("media_upload_contract", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("could not load media upload contract checker")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


swift = CHECKER.SWIFT_SOURCE.read_text(encoding="utf-8")
java = CHECKER.JAVA_SOURCE.read_text(encoding="utf-8")
swift_images = CHECKER.swift_extensions(swift, "imageFileExtensions")
swift_videos = CHECKER.swift_extensions(swift, "videoFileExtensions")
java_images, java_videos = CHECKER.java_extensions(java)
require(swift_images == java_images, "current image allowlists must match")
require(swift_videos == java_videos, "current video allowlists must match")
CHECKER.validate_contract(swift, java)

drifted_java = java.replace('case "webm":', 'case "futurewebm":', 1)
try:
    CHECKER.validate_contract(swift, drifted_java)
except ValueError:
    pass
else:
    raise AssertionError("one-sided Android drift must be rejected")

duplicated_swift = swift.replace('"webp",', '"webp", "webp",', 1)
try:
    CHECKER.swift_extensions(duplicated_swift, "imageFileExtensions")
except ValueError:
    pass
else:
    raise AssertionError("duplicate Swift extensions must be rejected")

ts_swift = swift.replace('"webp",', '"webp", "ts",', 1)
ts_java = java.replace(
    "            default: return null;",
    '            case "ts": return "image/x-test";\n            default: return null;',
    1,
)
try:
    CHECKER.validate_contract(ts_swift, ts_java)
except ValueError:
    pass
else:
    raise AssertionError("cross-platform .ts image admission must be rejected")
print("Media upload contract checker offline tests passed.")
print("中文：媒体上传契约检查器离线测试通过。")
