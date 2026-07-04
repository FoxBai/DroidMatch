#!/usr/bin/env python3
"""Frame-aware TCP fault proxy for M1 harness smoke tests."""

import argparse
import socket
import struct
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


def pipe_server_frames(source, destination, stop_event, drop_after_frames):
    frames = 0
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
            destination.sendall(header + payload)
            frames += 1
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


def handle_connection(client, target_host, target_port, drop_after_frames):
    upstream = socket.create_connection((target_host, target_port))
    stop_event = threading.Event()
    client_to_upstream = threading.Thread(
        target=pipe_raw,
        args=(client, upstream, stop_event),
        daemon=True,
    )
    upstream_to_client = threading.Thread(
        target=pipe_server_frames,
        args=(upstream, client, stop_event, drop_after_frames),
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
            with client:
                handle_connection(
                    client,
                    args.target_host,
                    args.target_port,
                    drop_after_frames,
                )


if __name__ == "__main__":
    main()
