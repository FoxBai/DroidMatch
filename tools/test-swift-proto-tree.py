#!/usr/bin/env python3
"""Exercise schema-set migration with the real transactional publisher, offline."""

import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parent
VALIDATE = runpy.run_path(str(TOOLS / "swift-proto-tree.py"))["validate"]


class SchemaMigrationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="droidmatch-proto-migration-")
        self.addCleanup(self.scratch.cleanup)
        self.repo = Path(self.scratch.name).resolve() / "repo"
        self.output = self.repo / "mac/Sources/DroidMatchCore/Generated"
        self.schemas = self.repo / "proto/v1"
        (self.repo / "tools").mkdir(parents=True)
        self.schemas.mkdir(parents=True)
        (self.output / "v1").mkdir(parents=True)
        for name in ("generate-swift-proto.sh", "swift-proto-tree.py"):
            shutil.copyfile(TOOLS / name, self.repo / "tools" / name)
        (self.schemas / "a.proto").write_text('syntax = "proto3";\n')
        (self.schemas / "compatibility-baseline.json").write_text("{}\n")
        self.original = b"old a.pb.swift\n"
        (self.output / "v1/a.pb.swift").write_bytes(self.original)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0")
        self.git("init", "--template=", "-q")
        self.commit()
        mock = self.repo / "mock-protoc"
        mock.write_text('''#!/usr/bin/env python3
from pathlib import Path
import sys
out = Path(next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--swift_out=")))
(out / "v1").mkdir()
for schema in Path("proto/v1").glob("*.proto"):
    name = schema.stem + ".pb.swift"
    (out / "v1" / name).write_text("generated " + name + "\\n")
''')
        mock.chmod(0o755)
        self.env.update(PROTOC=str(mock), PROTOC_GEN_SWIFT=str(mock),
                        SWIFT_PROTO_OUTPUT_DIR=str(self.output))

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.repo), "-c", "core.hooksPath=/dev/null",
             "-c", "commit.gpgSign=false", "-c", "user.name=Fixture",
             "-c", "user.email=fixture@example.invalid", *args],
            env=self.env, check=True, capture_output=True, timeout=10)

    def commit(self):
        self.git("add", "--", "proto", "mac")
        self.git("commit", "-qm", "Fixture schema and generated tree")

    def generate(self, successful):
        result = subprocess.run(["bash", "tools/generate-swift-proto.sh"], cwd=self.repo,
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, successful, result.stdout + result.stderr)
        self.assertFalse((self.output.parent / ".Generated.transaction").exists())

    def test_add_and_remove_schema_publish_complete_current_shape(self):
        (self.schemas / "b.proto").write_text('syntax = "proto3";\n')
        self.generate(True)
        self.assertEqual({p.name for p in (self.output / "v1").iterdir()},
                         {"a.pb.swift", "b.pb.swift"})
        self.assertEqual((self.output / "v1/a.pb.swift").read_text(), "generated a.pb.swift\n")
        self.commit()
        (self.schemas / "b.proto").unlink()
        self.generate(True)
        self.assertEqual({p.name for p in (self.output / "v1").iterdir()}, {"a.pb.swift"})

    def test_modified_or_incomplete_predecessor_is_preserved(self):
        (self.schemas / "b.proto").write_text('syntax = "proto3";\n')
        source = self.output / "v1/a.pb.swift"
        changed = self.original + b"uncommitted user change\n"
        source.write_bytes(changed)
        self.generate(False)
        self.assertEqual(source.read_bytes(), changed)
        source.unlink()
        self.generate(False)
        self.assertEqual(list((self.output / "v1").iterdir()), [])

    def test_committed_shape_is_only_allowed_as_canonical_predecessor(self):
        expected = ["a.pb.swift", "b.pb.swift"]
        values = (str(self.output), False, False)
        VALIDATE(*values, True, str(self.repo), str(self.output), expected)
        with self.assertRaises(RuntimeError):
            VALIDATE(*values, False, str(self.repo), str(self.output), expected)
        with self.assertRaises(RuntimeError):
            VALIDATE(*values, True, str(self.repo), str(self.repo / "ExternalGenerated"), expected)
        # A committed but incomplete generated inventory is not an approved base.
        (self.schemas / "c.proto").write_text('syntax = "proto3";\n')
        self.commit()
        with self.assertRaises(RuntimeError):
            VALIDATE(*values, True, str(self.repo), str(self.output), expected)


if __name__ == "__main__":
    unittest.main()
