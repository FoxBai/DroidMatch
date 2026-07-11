#!/usr/bin/env python3
"""Unit coverage for source classification and the documentation marker."""

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

print("Source-size checker tests passed.")
print("中文：源码规模检查器测试通过。")
