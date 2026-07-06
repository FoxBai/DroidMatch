#!/usr/bin/env python3
"""Frame-aware TCP fault proxy for M1 harness smoke tests."""

import argparse
import socket
import struct
import subprocess
import sys
import threading
from pathlib import Path


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
    parser.add_argument("--after-first-server-frames-command", default="")
    parser.add_argument("--after-first-server-frames-command-timeout", type=float, default=30.0)
    parser.add_argument("--max-connections", type=int, default=2)
    return parser.parse_args()


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


def run_hook_command(command, timeout_seconds):
    if not command:
        return
    print(
        f"fault proxy hook command: {command}",
        file=sys.stderr,
        flush=True,
    )
    try:
        completed = subprocess.run(
            command,
            shell=True,
            text=True,
            capture_output=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        print(
            f"fault proxy hook command timed out after {timeout_seconds:.1f}s",
            file=sys.stderr,
            flush=True,
        )
        if exc.stdout:
            print(exc.stdout, file=sys.stderr, end="", flush=True)
        if exc.stderr:
            print(exc.stderr, file=sys.stderr, end="", flush=True)
        return

    print(
        f"fault proxy hook command status={completed.returncode}",
        file=sys.stderr,
        flush=True,
    )
    if completed.stdout:
        print(completed.stdout, file=sys.stderr, end="", flush=True)
    if completed.stderr:
        print(completed.stderr, file=sys.stderr, end="", flush=True)


def pipe_server_frames(
    source,
    destination,
    stop_event,
    drop_after_frames,
    drop_before_frame,
    hook_after_frames,
    hook_command,
    hook_timeout_seconds,
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
                run_hook_command(hook_command, hook_timeout_seconds)
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
):
    upstream = socket.create_connection((target_host, target_port))
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
        ),
        daemon=True,
    )
    client_to_upstream.start()
    upstream_to_client.start()
    client_to_upstream.join()
    upstream_to_client.join()


def main():
    args = parse_args()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((args.listen_host, args.listen_port))
        listener.listen()
        actual_port = listener.getsockname()[1]
        if args.port_file:
            Path(args.port_file).write_text(f"{actual_port}\n", encoding="utf-8")
        print(f"listening_port={actual_port}", flush=True)

        for connection_index in range(args.max_connections):
            client, address = listener.accept()
            print(
                f"fault proxy accepted connection {connection_index + 1} from {address[0]}:{address[1]}",
                file=sys.stderr,
                flush=True,
            )
            drop_after_frames = args.drop_first_server_frames if connection_index == 0 else 0
            drop_before_frame = args.drop_before_first_server_frame if connection_index == 0 else 0
            hook_after_frames = args.run_command_after_first_server_frames if connection_index == 0 else 0
            hook_command = args.after_first_server_frames_command if connection_index == 0 else ""
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
                )


if __name__ == "__main__":
    main()
