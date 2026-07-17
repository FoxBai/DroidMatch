#!/usr/bin/env python3
"""Unit coverage for source classification and current-size documentation."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-source-size.py")
spec = spec_from_file_location("check_source_size", SCRIPT)
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
spec.loader.exec_module(module)

assert module.is_test_source(Path("mac/Tests/CoreTests/Example.swift"))
assert module.is_test_source(Path("android/app/src/test/java/example/Test.java"))
assert module.is_test_source(Path("android/app/src/androidTest/java/example/Test.java"))
assert not module.is_test_source(Path("mac/Sources/Core/Example.swift"))
assert not module.is_test_source(Path("android/app/src/main/java/example/Main.java"))
assert module.TOOL_SUFFIXES == {".sh", ".py"}
assert all(
    path.suffix in module.TOOL_SUFFIXES
    for path in module.handwritten_tool_files()
)

marker = (
    "<!-- source-size-max production=mac/Sources/Core.swift:12 "
    "test=mac/Tests/CoreTests.swift:34 -->"
)
assert module.maximum_marker(marker) == (
    "mac/Sources/Core.swift",
    12,
    "mac/Tests/CoreTests.swift",
    34,
)
assert module.maximum_marker("no marker") is None
assert module.tool_maximum_marker(
    "<!-- tool-size-max path=tools/run-example.sh:901 -->"
) == ("tools/run-example.sh", 901)
assert module.tool_maximum_marker("no tool marker") is None

assert module.tool_budget_failures(
    [(800, "tools/new-tool.sh")],
    {},
) == []
assert module.tool_budget_failures(
    [(801, "tools/new-tool.sh")],
    {},
) == ["tools/new-tool.sh: 801 lines exceeds tool ceiling 800"]
assert module.tool_budget_failures(
    [(901, "tools/legacy.sh")],
    {"tools/legacy.sh": 901},
) == []
assert module.tool_budget_failures(
    [(902, "tools/legacy.sh")],
    {"tools/legacy.sh": 901},
) == ["tools/legacy.sh: 902 lines exceeds tool ceiling 901"]
assert module.tool_budget_failures(
    [(850, "tools/legacy.sh")],
    {"tools/legacy.sh": 901},
) == ["tools/legacy.sh: now 850 lines; lower its tool ceiling from 901"]
assert module.tool_budget_failures(
    [],
    {"tools/missing.sh": 901},
) == ["tools/missing.sh: tool exception points to a missing script"]

actual = (
    "mac/Sources/Core/Writer.swift",
    12,
    "android/app/src/test/java/example/LargeTest.java",
    34,
)
claims = (
    "the largest production file is now the 12-line Mac `Writer.swift` and "
    "the largest test file is now the 34-line Android `LargeTest.java`.\n"
    "最大生产文件现为 12 行的 Mac `Writer.swift`，"
    "最大测试文件现为 34 行的 Android `LargeTest.java`。\n"
)
assert module.current_maximum_claim_failures(claims, actual) == []

stale_claims = claims.replace("12-line", "11-line").replace("12 行", "11 行")
stale_failures = module.current_maximum_claim_failures(stale_claims, actual)
assert len(stale_failures) == 2
assert all("claim is stale" in failure for failure in stale_failures)

missing_chinese = module.current_maximum_claim_failures(claims.splitlines()[0], actual)
assert any("canonical Chinese" in failure for failure in missing_chinese)

duplicate_english = module.current_maximum_claim_failures(
    claims + claims.splitlines()[0],
    actual,
)
assert any("canonical English" in failure for failure in duplicate_english)

print("Source-size checker tests passed.")
print("中文：源码规模检查器测试通过。")
