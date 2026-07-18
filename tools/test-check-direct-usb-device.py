#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import plistlib
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("check-direct-usb-device.py")
SPEC = importlib.util.spec_from_file_location("check_direct_usb_device", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)

SERIAL = "RAW-SERIAL-DO-NOT-LEAK"


def node(name: str, *, serial: object = None, device_class: object = None, children=()):
    value = {
        "IORegistryEntryName": name,
        "IORegistryEntryChildren": list(children),
    }
    if serial is not None:
        value["USB Serial Number"] = serial
    if device_class is not None:
        value["bDeviceClass"] = device_class
    return value


def tree_with(*children):
    return [node("Root", children=(node("AppleUSBXHCI", children=children),))]


class TopologyTests(unittest.TestCase):
    def test_direct_device_passes(self):
        CHECKER.verify_direct_tree(tree_with(node("Android", serial=SERIAL)), SERIAL)

    def test_byte_serial_passes(self):
        CHECKER.verify_direct_tree(
            tree_with(node("Android", serial=SERIAL.encode("utf-8"))), SERIAL
        )

    def test_hub_name_fails(self):
        tree = tree_with(node("USB2.1 Hub", children=(node("Android", serial=SERIAL),)))
        with self.assertRaisesRegex(CHECKER.DirectUsbError, "behind a hub"):
            CHECKER.verify_direct_tree(tree, SERIAL)

    def test_hub_class_fails_without_hub_name(self):
        tree = tree_with(
            node("Intermediate", device_class="0x09", children=(node("Android", serial=SERIAL),))
        )
        with self.assertRaisesRegex(CHECKER.DirectUsbError, "behind a hub"):
            CHECKER.verify_direct_tree(tree, SERIAL)

    def test_missing_device_fails(self):
        with self.assertRaisesRegex(CHECKER.DirectUsbError, "matched uniquely"):
            CHECKER.verify_direct_tree(tree_with(node("Android", serial="another")), SERIAL)

    def test_duplicate_device_fails(self):
        with self.assertRaisesRegex(CHECKER.DirectUsbError, "matched uniquely"):
            CHECKER.verify_direct_tree(
                tree_with(node("Android A", serial=SERIAL), node("Android B", serial=SERIAL)),
                SERIAL,
            )

    def test_unapproved_serial_property_does_not_match(self):
        device = node("Android")
        device["Arbitrary Serial Alias"] = SERIAL
        with self.assertRaisesRegex(CHECKER.DirectUsbError, "matched uniquely"):
            CHECKER.verify_direct_tree(tree_with(device), SERIAL)

    def test_missing_controller_fails(self):
        with self.assertRaisesRegex(CHECKER.DirectUsbError, "host controller"):
            CHECKER.verify_direct_tree([node("Android", serial=SERIAL)], SERIAL)


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.payload = plistlib.dumps(tree_with(node("Android", serial=SERIAL)))

    @mock.patch.object(CHECKER.os, "access", return_value=True)
    @mock.patch.object(CHECKER.sys, "platform", "darwin")
    @mock.patch.object(CHECKER, "_read_bounded")
    def test_registry_read_uses_bounded_reader(self, read_bounded, _access):
        read_bounded.return_value = self.payload
        self.assertIsInstance(CHECKER.read_ioreg_tree(), list)
        read_bounded.assert_called_once_with(
            ["/usr/sbin/ioreg", "-a", "-p", "IOUSB", "-l", "-w0"]
        )

    @mock.patch.object(CHECKER.os, "access", return_value=True)
    @mock.patch.object(CHECKER.sys, "platform", "darwin")
    @mock.patch.object(CHECKER, "_read_bounded", return_value=SERIAL.encode())
    def test_malformed_registry_fails_without_echoing_bytes(self, _read, _access):
        with self.assertRaisesRegex(CHECKER.DirectUsbError, "could not be parsed") as caught:
            CHECKER.read_ioreg_tree()
        self.assertNotIn(SERIAL, str(caught.exception))

    def test_bounded_reader_stops_at_limit(self):
        command = [sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'x'*65)"]
        with mock.patch.object(CHECKER, "MAX_IOREG_BYTES", 64):
            with self.assertRaisesRegex(CHECKER.DirectUsbError, "size bound"):
                CHECKER._read_bounded(command)

    def test_bounded_reader_enforces_timeout(self):
        command = [sys.executable, "-c", "import time;time.sleep(1)"]
        with self.assertRaisesRegex(CHECKER.DirectUsbError, "timed out"):
            CHECKER._read_bounded(command, timeout=0.02)

    def test_bounded_reader_rejects_nonzero_exit(self):
        command = [sys.executable, "-c", "raise SystemExit(9)"]
        with self.assertRaisesRegex(CHECKER.DirectUsbError, "could not be read"):
            CHECKER._read_bounded(command)

    def test_oversized_registry_error_does_not_echo_payload(self):
        command = [sys.executable, "-c", "import sys;sys.stdout.write('PRIVATE'*20)"]
        with mock.patch.object(CHECKER, "MAX_IOREG_BYTES", 32):
            with self.assertRaises(CHECKER.DirectUsbError) as caught:
                CHECKER._read_bounded(command)
        self.assertNotIn("PRIVATE", str(caught.exception))


class CommandTests(unittest.TestCase):
    def test_success_output_is_fixed(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        direct = tree_with(node("Android", serial=SERIAL))
        with mock.patch.object(CHECKER, "read_ioreg_tree", return_value=direct):
            with redirect_stdout(stdout), redirect_stderr(stderr):
                status = CHECKER.main(["--serial", SERIAL])
        self.assertEqual(status, 0)
        self.assertEqual(stdout.getvalue(), "direct USB topology verified\n")
        self.assertEqual(stderr.getvalue(), "")
        self.assertNotIn(SERIAL, stdout.getvalue())

    def test_failure_output_never_echoes_serial(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(CHECKER, "read_ioreg_tree", return_value=tree_with()):
            with redirect_stdout(stdout), redirect_stderr(stderr):
                status = CHECKER.main(["--serial", SERIAL])
        self.assertEqual(status, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertNotIn(SERIAL, stderr.getvalue())

    def test_invalid_invocation_never_echoes_argument(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = CHECKER.main(["--serial", "secret with spaces"])
        self.assertEqual(status, 2)
        self.assertEqual(stdout.getvalue(), "")
        self.assertNotIn("secret with spaces", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
