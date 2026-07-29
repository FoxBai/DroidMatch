#!/usr/bin/env python3
"""Frame-aware TCP fault proxy for M1 harness smoke tests."""

import argparse
import importlib.util
import json
import math
import os
import re
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


HOOK_TERMINATE_GRACE_SECONDS = 0.25
_active_hook_process = None
_active_hook_lock = threading.Lock()
_shutdown_requested = False
_shutdown_signum = None
_hook_cleanup_confirmed = True
_hook_start_decision = {}


class ProxyTerminationRequested(SystemExit):
    """Raised after the polling path finishes signal-requested hook cleanup."""

    def __init__(self, signum):
        super().__init__(128 + signum)
        self.signum = signum


class HookShutdownRequested(RuntimeError):
    """Raised when a hook spawn loses the race with proxy shutdown."""


class HookCleanupUnconfirmed(RuntimeError):
    """Raised when the proxy cannot prove that the complete hook group stopped."""


def positive_finite_seconds(value):
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("timeout must be finite and greater than zero")
    return parsed


def parse_args():
    parser = argparse.ArgumentParser(
        description="Proxy M1 framed TCP traffic and drop the first connection after N server frames."
    )
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=0)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, required=True)
    parser.add_argument("--port-file", default="")
    parser.add_argument("--drop-first-server-frames", type=int, default=3)
    parser.add_argument("--drop-before-first-server-frame", type=int, default=0)
    parser.add_argument("--run-command-after-first-server-frames", type=int, default=0)
    parser.add_argument(
        "--after-first-server-frames-command-timeout",
        type=positive_finite_seconds,
        default=30.0,
    )
    parser.add_argument("--max-connections", type=int, default=2)
    parser.add_argument("--shutdown-status-file", default="")
    parser.add_argument("--shutdown-request-file", default="")
    parser.add_argument("--identity-file", default="")
    parser.add_argument("--identity-tool", default="")
    parser.add_argument("--shutdown-token", default="")
    parser.add_argument("--hook-state-directory", default="")
    parser.add_argument(
        "--after-first-server-frames-command",
        nargs=argparse.REMAINDER,
        default=[],
        metavar="ARGV",
        help="Explicit hook argv. This option must be last because all remaining arguments belong to the hook.",
    )
    args = parser.parse_args()
    lifecycle_arguments = (
        bool(args.shutdown_status_file),
        bool(args.shutdown_request_file),
        bool(args.identity_file),
        bool(args.identity_tool),
        bool(args.shutdown_token),
    )
    if any(lifecycle_arguments) and not all(lifecycle_arguments):
        parser.error(
            "--shutdown-status-file, --shutdown-request-file, --identity-file, "
            "--identity-tool, and --shutdown-token must be used together"
        )
    if args.shutdown_token and (
        len(args.shutdown_token) != 32
        or any(character not in "0123456789abcdef" for character in args.shutdown_token)
    ):
        parser.error("--shutdown-token must be 32 lowercase hexadecimal characters")
    return args


def recvall(sock, byte_count):
    data = bytearray()
    while len(data) < byte_count:
        chunk = sock.recv(byte_count - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


def close_socket(sock):
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


def pipe_raw(source, destination, stop_event):
    try:
        while not stop_event.is_set():
            data = source.recv(64 * 1024)
            if not data:
                break
            destination.sendall(data)
    except OSError:
        pass
    finally:
        stop_event.set()
        close_socket(source)
        close_socket(destination)


def terminate_process_group(process, grace_seconds=HOOK_TERMINATE_GRACE_SECONDS):
    cleanup_lock = process._droidmatch_cleanup_lock
    with cleanup_lock:
        if process._droidmatch_cleanup_complete:
            return process._droidmatch_cleanup_confirmed
        confirmed = True
        process_group = process.pid
        try:
            os.killpg(process_group, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except OSError:
            confirmed = False

        # Do not reap or poll the supervisor before the final group signal. Its
        # unreaped session-leader PID keeps the PGID reserved, so killpg cannot
        # target a newly reused group.
        deadline = time.monotonic() + grace_seconds
        while time.monotonic() < deadline:
            time.sleep(0.01)
        try:
            os.killpg(process_group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError:
            confirmed = False
        try:
            process.wait(timeout=max(1.0, grace_seconds))
        except (OSError, subprocess.TimeoutExpired):
            confirmed = False
        if process.stdin is not None:
            try:
                process.stdin.close()
            except (OSError, ValueError):
                pass
        process._droidmatch_cleanup_complete = True
        process._droidmatch_cleanup_confirmed = confirmed
        return confirmed


def claim_hook_start():
    # One setdefault call is the start/shutdown linearization point: whichever
    # transition reaches the GIL-protected dictionary mutation first wins.
    return _hook_start_decision.setdefault("decision", "start") == "start"


def request_shutdown_transition(signum):
    global _shutdown_requested, _shutdown_signum
    _hook_start_decision.setdefault("decision", "shutdown")
    _shutdown_requested = True
    if _shutdown_signum is None:
        _shutdown_signum = signum


def start_hook_process(command_argv, result_file):
    global _active_hook_process, _hook_cleanup_confirmed
    # Publish the gated supervisor while holding the lock. A TERM/HUP observed
    # during Popen prevents the start byte; afterward the active group is visible
    # to bounded shutdown before the hook can run for more than that race window.
    with _active_hook_lock:
        if _shutdown_requested:
            raise HookShutdownRequested("fault proxy shutdown already requested")
        process = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).with_name("m1-hook-supervisor.py")),
                "--result-file",
                str(result_file),
                "--",
                *command_argv,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        process._droidmatch_cleanup_lock = threading.Lock()
        process._droidmatch_cleanup_complete = False
        process._droidmatch_cleanup_confirmed = False
        _active_hook_process = process
    if not claim_hook_start():
        if not terminate_process_group(process):
            _hook_cleanup_confirmed = False
        clear_active_hook_process(process)
        if not _hook_cleanup_confirmed:
            raise HookCleanupUnconfirmed(
                "hook supervisor cleanup failed before start authorization"
            )
        raise HookShutdownRequested("fault proxy shutdown raced with hook spawn")
    try:
        process.stdin.write(b"S")
        process.stdin.flush()
    except (BrokenPipeError, OSError, ValueError):
        cleanup_confirmed = terminate_process_group(process)
        if not cleanup_confirmed:
            _hook_cleanup_confirmed = False
        clear_active_hook_process(process)
        if cleanup_confirmed and _shutdown_requested:
            raise HookShutdownRequested(
                "fault proxy shutdown closed the hook start gate"
            )
        raise HookCleanupUnconfirmed("hook supervisor start gate failed")
    return process


def clear_active_hook_process(process):
    global _active_hook_process
    with _active_hook_lock:
        if _active_hook_process is process:
            _active_hook_process = None


def request_hook_shutdown():
    global _hook_cleanup_confirmed, _shutdown_requested
    _hook_start_decision.setdefault("decision", "shutdown")
    with _active_hook_lock:
        _shutdown_requested = True
        process = _active_hook_process
    if process is not None:
        if not terminate_process_group(process):
            _hook_cleanup_confirmed = False
    return _hook_cleanup_confirmed


def handle_termination_signal(signum, _frame):
    # Python dispatches signal handlers on the main thread. This handler is only
    # a state transition: it never acquires the hook lock, waits for children,
    # or raises through an in-progress cleanup. The listener/connection loops
    # poll this state and own the bounded shutdown on their normal control path.
    request_shutdown_transition(signum)


def install_termination_signal_handlers():
    signal.signal(signal.SIGTERM, handle_termination_signal)
    signal.signal(signal.SIGHUP, handle_termination_signal)


def shutdown_request_matches(path, token):
    flags = os.O_RDONLY | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except (FileNotFoundError, OSError):
        return False
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            return False
        with os.fdopen(descriptor, "r", encoding="ascii") as source:
            descriptor = -1
            request = source.read(256)
    except (OSError, UnicodeError):
        return False
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return request == f"shutdown {token}\n"


def poll_shutdown_request(path, token):
    if path and token and shutdown_request_matches(path, token):
        request_shutdown_transition(signal.SIGTERM)
    return _shutdown_requested


def read_hook_result(result_file):
    payload = json.loads(result_file.read_text(encoding="utf-8"))
    if (
        not isinstance(payload, dict)
        or not isinstance(payload.get("returncode"), int)
        or not isinstance(payload.get("stdout"), str)
        or not isinstance(payload.get("stderr"), str)
    ):
        raise ValueError("hook supervisor returned an invalid result")
    return payload


def run_hook_command(command_argv, timeout_seconds, state_directory=None):
    global _hook_cleanup_confirmed
    if not command_argv:
        return
    if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise ValueError("hook timeout must be finite and greater than zero")
    temporary_parent = str(state_directory) if state_directory else None
    with tempfile.TemporaryDirectory(
        prefix="droidmatch-hook-state.", dir=temporary_parent
    ) as hook_state:
        result_file = Path(hook_state) / "result.json"
        try:
            process = start_hook_process(command_argv, result_file)
        except HookShutdownRequested:
            print(
                "fault proxy hook command skipped because shutdown was requested",
                file=sys.stderr,
                flush=True,
            )
            return
        print(
            "fault proxy hook command started",
            file=sys.stderr,
            flush=True,
        )
        deadline = time.monotonic() + timeout_seconds
        timed_out = False
        interrupted_signum = None
        result = None
        try:
            while True:
                if result_file.is_file() and not result_file.is_symlink():
                    result = read_hook_result(result_file)
                    break
                if _shutdown_requested:
                    interrupted_signum = _shutdown_signum or signal.SIGTERM
                    break
                if time.monotonic() >= deadline:
                    timed_out = True
                    break
                time.sleep(0.05)
        finally:
            if not terminate_process_group(process):
                _hook_cleanup_confirmed = False
            clear_active_hook_process(process)

        if not _hook_cleanup_confirmed:
            raise HookCleanupUnconfirmed(
                "fault proxy could not verify hook process-group cleanup"
            )
        stdout = result["stdout"] if result is not None else ""
        stderr = result["stderr"] if result is not None else ""

        if timed_out:
            print(
                f"fault proxy hook command timed out after {timeout_seconds:.1f}s",
                file=sys.stderr,
                flush=True,
            )
            if stdout:
                print(stdout, file=sys.stderr, end="", flush=True)
            if stderr:
                print(stderr, file=sys.stderr, end="", flush=True)
            return
        if interrupted_signum is not None:
            print(
                "fault proxy hook command interrupted by proxy shutdown",
                file=sys.stderr,
                flush=True,
            )
            raise ProxyTerminationRequested(interrupted_signum)

        print(
            f"fault proxy hook command status={result['returncode']}",
            file=sys.stderr,
            flush=True,
        )
        if stdout:
            print(stdout, file=sys.stderr, end="", flush=True)
        if stderr:
            print(stderr, file=sys.stderr, end="", flush=True)


def write_clean_shutdown_status(path, token):
    write_atomic_text(path, f"clean {token}\n")


def write_atomic_text(path, content):
    destination = Path(path)
    temporary = destination.with_name(f"{destination.name}.new.{os.getpid()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as status:
            status.write(content)
            status.flush()
            os.fsync(status.fileno())
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise
    os.replace(temporary, destination)


def publish_process_identity(path, identity_tool, token):
    specification = importlib.util.spec_from_file_location(
        "droidmatch_fault_proxy_identity",
        identity_tool,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("fault proxy identity tool could not be loaded")
    identity_module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(identity_module)
    identity = identity_module.process_identity(os.getpid())
    if (
        not isinstance(identity, str)
        or not re.fullmatch(r"[a-z0-9][a-z0-9:._-]{10,255}", identity)
    ):
        raise RuntimeError("fault proxy could not capture its process identity")
    write_atomic_text(path, f"{os.getpid()} {identity} {token}\n")


def pipe_server_frames(
    source,
    destination,
    stop_event,
    drop_after_frames,
    drop_before_frame,
    hook_after_frames,
    hook_command,
    hook_timeout_seconds,
    hook_state_directory,
):
    frames = 0
    hook_ran = False
    try:
        while not stop_event.is_set():
            header = recvall(source, 4)
            if header is None:
                break
            (length,) = struct.unpack(">I", header)
            if length == 0:
                break
            payload = recvall(source, length)
            if payload is None:
                break
            next_frame = frames + 1
            if drop_before_frame > 0 and next_frame >= drop_before_frame:
                print(
                    f"fault proxy dropped first connection before forwarding server frame {next_frame}",
                    file=sys.stderr,
                    flush=True,
                )
                break
            destination.sendall(header + payload)
            frames = next_frame
            if (
                not hook_ran
                and hook_command
                and hook_after_frames > 0
                and frames >= hook_after_frames
            ):
                hook_ran = True
                run_hook_command(
                    hook_command,
                    hook_timeout_seconds,
                    hook_state_directory,
                )
            if drop_after_frames > 0 and frames >= drop_after_frames:
                print(
                    f"fault proxy dropped first connection after {frames} server frame(s)",
                    file=sys.stderr,
                    flush=True,
                )
                break
    except OSError:
        pass
    finally:
        stop_event.set()
        close_socket(source)
        close_socket(destination)


def handle_connection(
    client,
    target_host,
    target_port,
    drop_after_frames,
    drop_before_frame,
    hook_after_frames,
    hook_command,
    hook_timeout_seconds,
    hook_state_directory,
    shutdown_request_file,
    shutdown_token,
):
    upstream = socket.create_connection((target_host, target_port), timeout=1.0)
    upstream.settimeout(None)
    stop_event = threading.Event()
    client_to_upstream = threading.Thread(
        target=pipe_raw,
        args=(client, upstream, stop_event),
        daemon=True,
    )
    upstream_to_client = threading.Thread(
        target=pipe_server_frames,
        args=(
            upstream,
            client,
            stop_event,
            drop_after_frames,
            drop_before_frame,
            hook_after_frames,
            hook_command,
            hook_timeout_seconds,
            hook_state_directory,
        ),
        daemon=True,
    )
    client_to_upstream.start()
    upstream_to_client.start()
    while client_to_upstream.is_alive() or upstream_to_client.is_alive():
        client_to_upstream.join(timeout=0.05)
        upstream_to_client.join(timeout=0.05)
        if poll_shutdown_request(shutdown_request_file, shutdown_token):
            stop_event.set()
            close_socket(client)
            close_socket(upstream)


def main():
    args = parse_args()
    install_termination_signal_handlers()
    cleanup_confirmed = False
    try:
        if args.identity_file:
            publish_process_identity(
                args.identity_file,
                args.identity_tool,
                args.shutdown_token,
            )
        poll_shutdown_request(
            args.shutdown_request_file,
            args.shutdown_token,
        )
        if not _shutdown_requested:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.bind((args.listen_host, args.listen_port))
                listener.listen()
                listener.settimeout(0.1)
                actual_port = listener.getsockname()[1]
                if args.port_file:
                    Path(args.port_file).write_text(
                        f"{actual_port}\n",
                        encoding="utf-8",
                    )
                print(f"listening_port={actual_port}", flush=True)

                connection_index = 0
                while connection_index < args.max_connections:
                    if poll_shutdown_request(
                        args.shutdown_request_file,
                        args.shutdown_token,
                    ):
                        break
                    try:
                        client, address = listener.accept()
                    except socket.timeout:
                        continue
                    print(
                        f"fault proxy accepted connection {connection_index + 1} from {address[0]}:{address[1]}",
                        file=sys.stderr,
                        flush=True,
                    )
                    drop_after_frames = args.drop_first_server_frames if connection_index == 0 else 0
                    drop_before_frame = args.drop_before_first_server_frame if connection_index == 0 else 0
                    hook_after_frames = args.run_command_after_first_server_frames if connection_index == 0 else 0
                    hook_command = args.after_first_server_frames_command if connection_index == 0 else []
                    with client:
                        handle_connection(
                            client,
                            args.target_host,
                            args.target_port,
                            drop_after_frames,
                            drop_before_frame,
                            hook_after_frames,
                            hook_command,
                            args.after_first_server_frames_command_timeout,
                            args.hook_state_directory or None,
                            args.shutdown_request_file,
                            args.shutdown_token,
                        )
                    connection_index += 1
    finally:
        cleanup_confirmed = request_hook_shutdown()
        if (
            cleanup_confirmed
            and args.shutdown_status_file
            and args.shutdown_token
        ):
            write_clean_shutdown_status(
                args.shutdown_status_file,
                args.shutdown_token,
            )
    if _shutdown_signum is not None:
        raise SystemExit(128 + _shutdown_signum)


if __name__ == "__main__":
    main()
