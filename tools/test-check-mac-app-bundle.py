#!/usr/bin/env python3
"""Offline contract tests for the Mac bundle verification boundary."""

import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import textwrap
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parent.parent
CHECKER = REPO_ROOT / "tools" / "check-mac-app-bundle.py"
EXPECTED_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.device.usb": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.network.client": True,
    "com.apple.security.network.server": True,
}

DARWIN_CHECKER_RUNNER = """
import os
import runpy
import subprocess
import sys

checker, app, defer_adb = sys.argv[1:]
expected_adb = os.environ["DROIDMATCH_TEST_ADB"]
calls_path = os.environ["DROIDMATCH_TEST_ADB_CALLS"]
real_run = subprocess.run

def run_with_adb_probe(arguments, *args, **kwargs):
    if list(arguments) == [expected_adb, "version"]:
        with open(calls_path, "a", encoding="utf-8") as calls:
            calls.write(expected_adb + "\\n")
        return subprocess.CompletedProcess(arguments, 0, b"", b"")
    return real_run(arguments, *args, **kwargs)

subprocess.run = run_with_adb_probe
sys.argv = [checker, "--sandboxed"]
if defer_adb == "true":
    sys.argv.append("--defer-adb-execution")
sys.argv.append(app)
runpy.run_path(checker, run_name="__main__")
"""


def write(path: Path, data: bytes, mode: Optional[int] = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    if mode is not None:
        path.chmod(mode)


def run_checker(
    app: Path,
    environment: dict,
    defer_adb_execution: bool = False,
) -> subprocess.CompletedProcess:
    command = [sys.executable, str(CHECKER), "--sandboxed"]
    if defer_adb_execution:
        command.append("--defer-adb-execution")
    command.append(str(app))
    if sys.platform == "darwin":
        command = [
            sys.executable,
            "-c",
            DARWIN_CHECKER_RUNNER,
            str(CHECKER),
            str(app),
            "true" if defer_adb_execution else "false",
        ]
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        env=environment,
    )


def require_fixed_failure(
    result: subprocess.CompletedProcess,
    expected_error: str,
    forbidden_text: str = "",
) -> None:
    if result.returncode != 1 or expected_error not in result.stderr:
        raise AssertionError(
            "bundle checker did not fail closed:\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
    if "Traceback" in result.stderr or (
        forbidden_text and forbidden_text in result.stderr
    ):
        raise AssertionError(f"bundle checker failure leaked detail:\n{result.stderr}")


with tempfile.TemporaryDirectory(prefix="droidmatch-bundle-check-") as raw_root:
    root = Path(raw_root)
    app = root / "DroidMatch.app"
    contents = app / "Contents"
    resources = contents / "Resources"
    resource_bundle = resources / "DroidMatchMac_DroidMatchApp.bundle"
    protobuf_bundle = resources / "SwiftProtobuf_SwiftProtobuf.bundle"
    platform_tools = resources / "platform-tools"

    info = {
        "CFBundleIdentifier": "app.droidmatch.mac",
        "CFBundleExecutable": "DroidMatch",
        "CFBundlePackageType": "APPL",
        "CFBundleLocalizations": ["en", "zh-Hans"],
        "LSMinimumSystemVersion": "13.0",
        "ITSAppUsesNonExemptEncryption": False,
        "DroidMatchSourceRevision": "a" * 40,
        "DroidMatchSourceDirty": True,
        "DroidMatchBuildConfiguration": "release",
    }
    write(contents / "Info.plist", plistlib.dumps(info))
    write(contents / "MacOS" / "DroidMatch", b"#!/bin/sh\nexit 0\n", 0o755)
    write(resources / "DroidMatch.icns", b"icon")
    write(resource_bundle / "Info.plist", b"bundle")
    write(resource_bundle / "en.lproj" / "Localizable.strings", b"english")
    write(resource_bundle / "zh-hans.lproj" / "Localizable.strings", b"chinese")
    write(
        resources / "PrivacyInfo.xcprivacy",
        plistlib.dumps({
            "NSPrivacyTracking": False,
            "NSPrivacyTrackingDomains": [],
            "NSPrivacyCollectedDataTypes": [],
            "NSPrivacyAccessedAPITypes": [],
        }),
    )
    write(
        protobuf_bundle / "PrivacyInfo.xcprivacy",
        plistlib.dumps({"NSPrivacyTracking": False}),
    )
    write(
        resources / "Legal" / "THIRD-PARTY-NOTICES.md",
        b"SwiftProtobuf 1.38.1 Apache License 2.0",
    )
    write(resources / "Legal" / "swift-protobuf-LICENSE.txt", b"license")
    write(platform_tools / "NOTICE.txt", b"platform tools notice")
    write(platform_tools / "adb", b"#!/bin/sh\nexit 0\n", 0o755)

    fake_bin = root / "fake-bin"
    calls = root / "codesign-calls.txt"
    adb_calls = root / "adb-calls.txt"
    entitlements = root / "entitlements.plist"
    write(entitlements, plistlib.dumps(EXPECTED_ENTITLEMENTS))
    write(
        fake_bin / "codesign",
        textwrap.dedent("""\
            #!/bin/sh
            printf '%s\\n' "$*" >>"$DROIDMATCH_CODESIGN_CALLS"
            if [ "${1:-}" = "-d" ]; then
              if [ "${2:-}" != "--entitlements" ] \
                  || [ "${3:-}" != "-" ] \
                  || [ "${4:-}" != "--xml" ]; then
                printf '%s\\n' 'deprecated or non-XML entitlement extraction' >&2
                exit 64
              fi
              if [ "${DROIDMATCH_CODESIGN_MODE:-valid}" = "malformed" ]; then
                printf '%s\\n' 'not an XML property list'
                exit 0
              fi
              /bin/cat "$DROIDMATCH_ENTITLEMENTS_PLIST"
            fi
            exit 0
        """).encode(),
        0o755,
    )

    environment = os.environ.copy()
    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
    environment["DROIDMATCH_CODESIGN_CALLS"] = str(calls)
    environment["DROIDMATCH_ENTITLEMENTS_PLIST"] = str(entitlements)
    environment["DROIDMATCH_TEST_ADB"] = str(platform_tools / "adb")
    environment["DROIDMATCH_TEST_ADB_CALLS"] = str(adb_calls)
    environment["DROIDMATCH_CODESIGN_MODE"] = "malformed"
    malformed = run_checker(app, environment)
    expected_error = (
        "Mac App bundle check failed: "
        "bundle entitlements are not a valid XML property list"
    )
    require_fixed_failure(malformed, expected_error, str(entitlements))

    environment["DROIDMATCH_CODESIGN_MODE"] = "valid"
    external_notice = root / "outside-notice.txt"
    write(external_notice, b"external platform tools notice")
    notice = platform_tools / "NOTICE.txt"
    notice.unlink()
    notice.symlink_to(external_notice)
    linked_resource = run_checker(app, environment)
    require_fixed_failure(
        linked_resource,
        "Mac App bundle check failed: App bundle must not contain symbolic links: "
        "Contents/Resources/platform-tools/NOTICE.txt",
        str(external_notice),
    )
    notice.unlink()
    write(notice, b"platform tools notice")

    notice.unlink()
    os.link(external_notice, notice)
    hard_linked_resource = run_checker(app, environment)
    require_fixed_failure(
        hard_linked_resource,
        "Mac App bundle check failed: App bundle files must have exactly one link: "
        "Contents/Resources/platform-tools/NOTICE.txt",
        str(external_notice),
    )
    notice.unlink()
    write(notice, b"platform tools notice")

    unexpected_pipe = resources / "unexpected.pipe"
    os.mkfifo(unexpected_pipe)
    special_node = run_checker(app, environment)
    require_fixed_failure(
        special_node,
        "Mac App bundle check failed: App bundle contains an unsupported filesystem node: "
        "Contents/Resources/unexpected.pipe",
    )
    unexpected_pipe.unlink()

    notice.chmod(0o666)
    writable_resource = run_checker(app, environment)
    require_fixed_failure(
        writable_resource,
        "Mac App bundle check failed: App bundle nodes must not be group/world writable: "
        "Contents/Resources/platform-tools/NOTICE.txt",
    )
    notice.chmod(0o644)

    notice.chmod(0o200)
    unreadable_resource = run_checker(app, environment)
    require_fixed_failure(
        unreadable_resource,
        "Mac App bundle check failed: App bundle files must be owner-readable: "
        "Contents/Resources/platform-tools/NOTICE.txt",
    )
    notice.chmod(0o644)

    unreadable_directory = resources / "unreadable"
    unreadable_directory.mkdir(mode=0o400)
    unreadable_subtree = run_checker(app, environment)
    require_fixed_failure(
        unreadable_subtree,
        "Mac App bundle check failed: "
        "App bundle directories must be owner-readable/traversable: "
        "Contents/Resources/unreadable",
    )
    unreadable_directory.chmod(0o700)
    unreadable_directory.rmdir()

    notice.chmod(0o1644)
    privileged_resource = run_checker(app, environment)
    require_fixed_failure(
        privileged_resource,
        "Mac App bundle check failed: App bundle nodes must not have special permission bits: "
        "Contents/Resources/platform-tools/NOTICE.txt",
    )
    notice.chmod(0o644)

    app_link = root / "DroidMatch-link.app"
    app_link.symlink_to(app, target_is_directory=True)
    linked_app = run_checker(app_link, environment)
    require_fixed_failure(
        linked_app,
        "Mac App bundle check failed: App bundle must not be a symbolic link",
        str(app),
    )

    # Run the complete success path last. Darwin injects only the final process
    # launch result because macOS may kill generated executables inside a
    # temporary unsigned .app; the wrapper records the exact adb path and argv.
    # Real App/DMG builds still run the production checker without injection.
    result = run_checker(app, environment)
    if result.returncode != 0:
        raise AssertionError(f"bundle checker failed:\n{result.stdout}\n{result.stderr}")

    recorded_calls = calls.read_text(encoding="utf-8")
    expected_display = f"-d --entitlements - --xml {app}"
    if expected_display not in recorded_calls or ":-" in recorded_calls:
        raise AssertionError(f"unexpected codesign contract:\n{recorded_calls}")
    if sys.platform == "darwin":
        if adb_calls.read_text(encoding="utf-8").splitlines() != [
            str(platform_tools / "adb")
        ]:
            raise AssertionError("bundle checker did not run the exact embedded adb")

    adb_calls.write_text("", encoding="utf-8")
    deferred_result = run_checker(app, environment, defer_adb_execution=True)
    if deferred_result.returncode != 0:
        raise AssertionError(
            "deferred candidate check failed:\n"
            f"{deferred_result.stdout}\n{deferred_result.stderr}"
        )
    if sys.platform == "darwin" and adb_calls.read_text(encoding="utf-8"):
        raise AssertionError("deferred candidate check executed embedded adb")

    ordinary_deferred = subprocess.run(
        [sys.executable, str(CHECKER), "--defer-adb-execution", str(app)],
        capture_output=True,
        text=True,
        env=environment,
    )
    require_fixed_failure(
        ordinary_deferred,
        "Mac App bundle check failed: adb execution can be deferred only for a sandboxed candidate",
    )

print("Mac bundle checker boundary tests passed.")
print("中文：Mac bundle 检查器边界回归测试通过。")
