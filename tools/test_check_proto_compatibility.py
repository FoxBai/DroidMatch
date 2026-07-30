#!/usr/bin/env python3

"""Regression tests for descriptor-backed protobuf compatibility checks."""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOL = REPO_ROOT / "tools" / "check_proto_compatibility.py"

BASE_PROTO = """\
syntax = "proto3";
package fixture.v1;

import public "v1/shared.proto";

option java_package = "example.fixture.v1";
option java_multiple_files = true;

message Sample {
  string name = 1;
  repeated uint32 counts = 2;
  oneof choice {
    string alias = 3;
    bytes token = 4;
  }
  map<string, string> labels = 5;
  .fixture.v1.Shared shared = 6;
}

enum Status {
  STATUS_UNSPECIFIED = 0;
  STATUS_READY = 1;
}
"""


def run(*arguments: str, expected: int) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, str(TOOL), *arguments],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == expected, (arguments, result)
    return result


def compile_descriptor_files(
    root: pathlib.Path,
    sources: dict[str, str],
    name: str,
    descriptor_inputs: list[str] | None = None,
) -> pathlib.Path:
    for relative_path, source in sources.items():
        proto_path = root / relative_path
        proto_path.parent.mkdir(parents=True, exist_ok=True)
        proto_path.write_text(source, encoding="utf-8")
    descriptor = root / f"{name}.pb"
    subprocess.run(
        [
            "protoc",
            f"--proto_path={root}",
            f"--descriptor_set_out={descriptor}",
            *(descriptor_inputs or sorted(sources)),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return descriptor


def compile_descriptor(root: pathlib.Path, source: str, name: str) -> pathlib.Path:
    return compile_descriptor_files(
        root,
        {
            "v1/fixture.proto": source,
            "v1/shared.proto": (
                'syntax = "proto3";\npackage fixture.v1;\nmessage Shared {}\n'
            ),
        },
        name,
    )


with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary)
    baseline_descriptor = compile_descriptor(root, BASE_PROTO, "baseline")
    baseline = root / "baseline.json"
    baseline_write = run(
        "--descriptor",
        str(baseline_descriptor),
        "--write-baseline",
        str(baseline),
        expected=0,
    )
    assert str(baseline) not in baseline_write.stdout + baseline_write.stderr
    run(
        "--descriptor",
        str(baseline_descriptor),
        "--baseline",
        str(baseline),
        expected=0,
    )
    overwrite = run(
        "--descriptor",
        str(baseline_descriptor),
        "--write-baseline",
        str(baseline),
        expected=2,
    )
    assert "refusing to replace" in overwrite.stderr

    fifo_descriptor = root / "descriptor.fifo"
    os.mkfifo(fifo_descriptor)
    fifo_result = run(
        "--descriptor",
        str(fifo_descriptor),
        "--baseline",
        str(baseline),
        expected=2,
    )
    assert "single-link regular file" in fifo_result.stderr

    duplicate_baseline = root / "duplicate-baseline.json"
    duplicate_baseline.write_text(
        baseline.read_text(encoding="utf-8").replace(
            '"schema_version": 2,',
            '"schema_version": 2,\n  "schema_version": 2,',
            1,
        ),
        encoding="utf-8",
    )
    duplicate_result = run(
        "--descriptor",
        str(baseline_descriptor),
        "--baseline",
        str(duplicate_baseline),
        expected=2,
    )
    assert "repeats JSON key" in duplicate_result.stderr

    incomplete_descriptor = compile_descriptor_files(
        root,
        {
            "hidden/main.proto": (
                'syntax = "proto3";\npackage fixture.hidden;\n'
                'import "hidden/shared.proto";\n'
                'message Main { Shared value = 1; }\n'
            ),
            "hidden/shared.proto": (
                'syntax = "proto3";\npackage fixture.hidden;\nmessage Shared {}\n'
            ),
        },
        "incomplete-imports",
        descriptor_inputs=["hidden/main.proto"],
    )
    incomplete = run(
        "--descriptor",
        str(incomplete_descriptor),
        "--write-baseline",
        str(root / "incomplete-imports.json"),
        expected=2,
    )
    assert "compile with --include_imports" in incomplete.stderr

    additive = BASE_PROTO.replace(
        "  .fixture.v1.Shared shared = 6;",
        "  .fixture.v1.Shared shared = 6;\n  bool enabled = 7;",
    ).replace(
        "  STATUS_READY = 1;",
        "  STATUS_READY = 1;\n  STATUS_DONE = 2;",
    )
    additive_descriptor = compile_descriptor(root, additive, "additive")
    stale = run(
        "--descriptor",
        str(additive_descriptor),
        "--baseline",
        str(baseline),
        expected=1,
    )
    assert "baseline is stale" in stale.stderr
    additive_baseline = root / "additive-baseline.json"
    run(
        "--descriptor",
        str(additive_descriptor),
        "--write-baseline",
        str(additive_baseline),
        expected=0,
    )
    run(
        "--descriptor",
        str(additive_descriptor),
        "--baseline",
        str(additive_baseline),
        "--previous-baseline",
        str(baseline),
        expected=0,
    )

    proto2_source = """\
syntax = "proto2";
package fixture.proto2;
message Existing {
  optional string stable = 1;
}
"""
    proto2_descriptor = compile_descriptor_files(
        root,
        {"proto2/existing.proto": proto2_source},
        "proto2-baseline",
    )
    proto2_baseline = root / "proto2-baseline.json"
    run(
        "--descriptor",
        str(proto2_descriptor),
        "--write-baseline",
        str(proto2_baseline),
        expected=0,
    )
    required_descriptor = compile_descriptor_files(
        root,
        {
            "proto2/existing.proto": proto2_source.replace(
                "  optional string stable = 1;",
                "  optional string stable = 1;\n  required string unsafe = 2;",
            )
        },
        "proto2-required",
    )
    required_baseline = root / "proto2-required.json"
    run(
        "--descriptor",
        str(required_descriptor),
        "--write-baseline",
        str(required_baseline),
        expected=0,
    )
    required_result = run(
        "--descriptor",
        str(required_descriptor),
        "--baseline",
        str(required_baseline),
        "--previous-baseline",
        str(proto2_baseline),
        expected=1,
    )
    assert "added a required field" in required_result.stderr

    breaking_cases = {
        "field-renumber": BASE_PROTO.replace("string name = 1;", "string name = 7;"),
        "field-type": BASE_PROTO.replace("string name = 1;", "bytes name = 1;"),
        "field-rename": BASE_PROTO.replace("string name = 1;", "string title = 1;"),
        "field-remove": BASE_PROTO.replace("  repeated uint32 counts = 2;\n", ""),
        "oneof-membership": BASE_PROTO.replace(
            "  oneof choice {\n    string alias = 3;\n    bytes token = 4;\n  }",
            "  string alias = 3;\n  oneof choice {\n    bytes token = 4;\n  }",
        ),
        "field-enters-oneof": BASE_PROTO.replace(
            "  string name = 1;",
            "  oneof identity {\n    string name = 1;\n  }",
        ),
        "packed-option": BASE_PROTO.replace(
            "repeated uint32 counts = 2;",
            "repeated uint32 counts = 2 [packed = false];",
        ),
        "map-value-type": BASE_PROTO.replace(
            "map<string, string> labels = 5;",
            "map<string, bytes> labels = 5;",
        ),
        "enum-renumber": BASE_PROTO.replace("STATUS_READY = 1;", "STATUS_READY = 2;"),
        "enum-remove": BASE_PROTO.replace("  STATUS_READY = 1;\n", ""),
        "package-change": BASE_PROTO.replace(
            "package fixture.v1;",
            "package fixture.v2;",
        ),
        "import-mode": BASE_PROTO.replace(
            'import public "v1/shared.proto";',
            'import "v1/shared.proto";',
        ),
    }
    for name, source in breaking_cases.items():
        descriptor = compile_descriptor(root, source, name)
        stale_result = run(
            "--descriptor",
            str(descriptor),
            "--baseline",
            str(baseline),
            expected=1,
        )
        assert "compatibility check failed" in stale_result.stderr.lower(), name
        candidate_baseline = root / f"{name}-baseline.json"
        run(
            "--descriptor",
            str(descriptor),
            "--write-baseline",
            str(candidate_baseline),
            expected=0,
        )
        previous_result = run(
            "--descriptor",
            str(descriptor),
            "--baseline",
            str(candidate_baseline),
            "--previous-baseline",
            str(baseline),
            expected=1,
        )
        assert "compatibility check failed" in previous_result.stderr.lower(), name

    removed_descriptor = compile_descriptor(
        root,
        BASE_PROTO.replace("  repeated uint32 counts = 2;\n", ""),
        "removed-with-new-baseline",
    )
    weakened_baseline = root / "weakened-baseline.json"
    run(
        "--descriptor",
        str(removed_descriptor),
        "--write-baseline",
        str(weakened_baseline),
        expected=0,
    )
    weakened = run(
        "--descriptor",
        str(removed_descriptor),
        "--baseline",
        str(weakened_baseline),
        "--previous-baseline",
        str(baseline),
        expected=1,
    )
    assert "fields.2 was removed" in weakened.stderr

    source_file_baseline_descriptor = compile_descriptor_files(
        root,
        {
            "move/a.proto": (
                'syntax = "proto3";\npackage fixture.move;\nmessage Stable {}\n'
            ),
            "move/b.proto": (
                'syntax = "proto3";\npackage fixture.move;\n'
                'import "move/a.proto";\nmessage Holder { Stable stable = 1; }\n'
            ),
        },
        "source-file-baseline",
    )
    source_file_baseline = root / "source-file-baseline.json"
    run(
        "--descriptor",
        str(source_file_baseline_descriptor),
        "--write-baseline",
        str(source_file_baseline),
        expected=0,
    )
    moved_descriptor = compile_descriptor_files(
        root,
        {
            "move/a.proto": 'syntax = "proto3";\npackage fixture.move;\n',
            "move/b.proto": (
                'syntax = "proto3";\npackage fixture.move;\n'
                'import "move/a.proto";\nmessage Stable {}\n'
                'message Holder { Stable stable = 1; }\n'
            ),
        },
        "source-file-moved",
    )
    moved = run(
        "--descriptor",
        str(moved_descriptor),
        "--baseline",
        str(source_file_baseline),
        expected=1,
    )
    assert "messages.fixture.move.Stable.file changed" in moved.stderr
    moved_baseline = root / "source-file-moved-baseline.json"
    run(
        "--descriptor",
        str(moved_descriptor),
        "--write-baseline",
        str(moved_baseline),
        expected=0,
    )
    moved_previous = run(
        "--descriptor",
        str(moved_descriptor),
        "--baseline",
        str(moved_baseline),
        "--previous-baseline",
        str(source_file_baseline),
        expected=1,
    )
    assert "messages.fixture.move.Stable.file changed" in moved_previous.stderr

    extension_source = """\
syntax = "proto2";
package fixture.v1;

message Extensible {
  extensions 100 to max;
}
"""
    extension_descriptor = compile_descriptor(root, extension_source, "extensions")
    unsupported = run(
        "--descriptor",
        str(extension_descriptor),
        "--baseline",
        str(baseline),
        expected=2,
    )
    assert "extensions" in unsupported.stderr

    gate_root = root / "main-gate-fixture"
    (gate_root / "tools").mkdir(parents=True)
    (gate_root / "proto" / "v1").mkdir(parents=True)
    shutil.copy2(TOOL, gate_root / "tools" / TOOL.name)
    shutil.copy2(
        REPO_ROOT / "tools" / "check-proto.sh",
        gate_root / "tools" / "check-proto.sh",
    )
    gate_proto = gate_root / "proto" / "v1" / "gate.proto"
    gate_baseline = gate_root / "proto" / "v1" / "compatibility-baseline.json"

    def generate_gate_baseline(source: str) -> None:
        gate_proto.write_text(source, encoding="utf-8")
        descriptor = gate_root / "gate.pb"
        subprocess.run(
            [
                "protoc",
                "--proto_path=proto",
                f"--descriptor_set_out={descriptor}",
                "proto/v1/gate.proto",
            ],
            cwd=gate_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        gate_baseline.unlink(missing_ok=True)
        subprocess.run(
            [
                sys.executable,
                "tools/check_proto_compatibility.py",
                "--descriptor",
                str(descriptor),
                "--write-baseline",
                str(gate_baseline),
            ],
            cwd=gate_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        descriptor.unlink()

    gate_source = """\
syntax = "proto3";
package fixture.gate;
message Stable {
  string first = 1;
  string second = 2;
}
"""
    generate_gate_baseline(gate_source)
    for git_arguments in (
        ("init", "-b", "main"),
        ("config", "user.name", "DroidMatch Gate Test"),
        ("config", "user.email", "gate-test@example.invalid"),
        ("add", "."),
        ("commit", "-m", "baseline"),
    ):
        subprocess.run(
            ["git", *git_arguments],
            cwd=gate_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    base_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=gate_root,
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    subprocess.run(
        ["git", "update-ref", "refs/remotes/origin/main", base_commit],
        cwd=gate_root,
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    empty_tree = subprocess.run(
        ["git", "mktree"],
        cwd=gate_root,
        input="",
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    replacement_commit = subprocess.run(
        ["git", "commit-tree", empty_tree, "-m", "replacement without baseline"],
        cwd=gate_root,
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    subprocess.run(
        ["git", "replace", base_commit, replacement_commit],
        cwd=gate_root,
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    generate_gate_baseline(gate_source.replace("  string second = 2;\n", ""))
    gate_environment = os.environ.copy()
    gate_environment.update(
        {
            "DROIDMATCH_PROTO_BASE_REF": "0" * 40,
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REF": "refs/heads/codex/main-gate/regression",
        }
    )
    first_push = subprocess.run(
        ["bash", "tools/check-proto.sh"],
        cwd=gate_root,
        env=gate_environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert first_push.returncode == 1, first_push
    assert "fields.2 was removed" in first_push.stderr

    for git_arguments in (
        ("add", "proto/v1/gate.proto", "proto/v1/compatibility-baseline.json"),
        ("commit", "-m", "weakened failed gate tip"),
    ):
        subprocess.run(
            ["git", *git_arguments],
            cwd=gate_root,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    weakened_tip = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=gate_root,
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    later_gate_environment = gate_environment.copy()
    later_gate_environment["DROIDMATCH_PROTO_BASE_REF"] = weakened_tip
    later_gate = subprocess.run(
        ["bash", "tools/check-proto.sh"],
        cwd=gate_root,
        env=later_gate_environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert later_gate.returncode == 1, later_gate
    assert "fields.2 was removed" in later_gate.stderr

    injected_environment = gate_environment.copy()
    injected_environment["DROIDMATCH_PROTO_BASE_REF"] = "HEAD^{tree}"
    injected_environment["GITHUB_EVENT_NAME"] = "pull_request"
    injected_environment["GITHUB_REF"] = "refs/pull/1/merge"
    injected = subprocess.run(
        ["bash", "tools/check-proto.sh"],
        cwd=gate_root,
        env=injected_environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert injected.returncode == 1, injected
    assert "must be a full commit SHA" in injected.stderr

    zero_main_environment = gate_environment.copy()
    zero_main_environment["GITHUB_REF"] = "refs/heads/main"
    zero_main = subprocess.run(
        ["bash", "tools/check-proto.sh"],
        cwd=gate_root,
        env=zero_main_environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert zero_main.returncode == 1, zero_main
    assert "no usable previous commit" in zero_main.stderr

    subprocess.run(
        ["git", "update-ref", "-d", "refs/remotes/origin/main"],
        cwd=gate_root,
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    missing_main = subprocess.run(
        ["bash", "tools/check-proto.sh"],
        cwd=gate_root,
        env=gate_environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert missing_main.returncode == 1, missing_main
    assert "main-gate base commit is unavailable" in missing_main.stderr

print("Proto compatibility checker regressions passed.")
print("中文：Protobuf 兼容性检查器离线回归通过。")
