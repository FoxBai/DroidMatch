"""Readiness handshake for offline USB process-cleanup fixtures."""

import time


def start_ready_process(popen, marker, cleanup, *args, **kwargs):
    process = popen(*args, **kwargs)
    # Start the short query deadline after the TERM-resistant fixture exists.
    # 先确认抗 TERM 的测试子进程就绪，避免把解释器冷启动误当作清理失败。
    deadline = time.monotonic() + 5.0
    while not marker.is_file():
        if process.poll() is not None or time.monotonic() >= deadline:
            try:
                cleanup(process)
            finally:
                if process.stdout is not None:
                    process.stdout.close()
            raise AssertionError("ADB identity timeout fixture did not become ready")
        time.sleep(0.02)
    return process
