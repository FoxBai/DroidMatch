#!/usr/bin/env python3
"""Parse one current Android user's complete SDK-specific media grant set."""

from __future__ import annotations

import argparse
import re
import sys


READ_EXTERNAL = "android.permission.READ_EXTERNAL_STORAGE"
READ_IMAGES = "android.permission.READ_MEDIA_IMAGES"
READ_VIDEO = "android.permission.READ_MEDIA_VIDEO"
READ_SELECTED = "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
TRACKED_PERMISSIONS = (
    READ_EXTERNAL,
    READ_IMAGES,
    READ_VIDEO,
    READ_SELECTED,
)
USER_HEADER = re.compile(r"^\s*User\s+([0-9]+):(?:\s|$)")
PERMISSION_STATE = re.compile(
    r"^\s*(android\.permission\."
    r"(?:READ_EXTERNAL_STORAGE|READ_MEDIA_IMAGES|READ_MEDIA_VIDEO|"
    r"READ_MEDIA_VISUAL_USER_SELECTED)):\s*"
    r"granted=(true|false)(?:,|\s*$)"
)


class SnapshotRejected(ValueError):
    """The package dump did not prove one complete current-user snapshot."""


def expected_permissions(sdk: int) -> tuple[str, ...]:
    if sdk < 26:
        raise SnapshotRejected("SDK is below the project minimum")
    if sdk >= 34:
        return (READ_IMAGES, READ_VIDEO, READ_SELECTED)
    if sdk == 33:
        return (READ_IMAGES, READ_VIDEO)
    return (READ_EXTERNAL,)


def current_user_blocks(package_state: str, current_user: int) -> list[list[str]]:
    blocks: list[list[str]] = []
    active: list[str] | None = None
    for line in package_state.splitlines():
        user_match = USER_HEADER.match(line)
        if user_match:
            if active is not None:
                blocks.append(active)
            active = [] if int(user_match.group(1)) == current_user else None
            continue
        if active is not None:
            active.append(line)
    if active is not None:
        blocks.append(active)
    return blocks


def parse_snapshot(package_state: str, sdk: int, current_user: int) -> tuple[int, ...]:
    if current_user < 0:
        raise SnapshotRejected("current user must be nonnegative")
    blocks = current_user_blocks(package_state, current_user)
    if len(blocks) != 1:
        raise SnapshotRejected("current user block is missing or ambiguous")

    observed: dict[str, list[bool]] = {
        permission: [] for permission in TRACKED_PERMISSIONS
    }
    for line in blocks[0]:
        permission_match = PERMISSION_STATE.match(line)
        if permission_match:
            observed[permission_match.group(1)].append(
                permission_match.group(2) == "true"
            )

    expected = set(expected_permissions(sdk))
    for permission in TRACKED_PERMISSIONS:
        states = observed[permission]
        if permission in expected:
            if len(states) != 1:
                raise SnapshotRejected(
                    "expected permission state is missing or duplicated"
                )
        elif states:
            raise SnapshotRejected("unexpected SDK permission state is present")
    return tuple(
        int(observed[permission][0]) if permission in expected else 0
        for permission in TRACKED_PERMISSIONS
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", type=int, required=True)
    parser.add_argument("--current-user", type=int, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        snapshot = parse_snapshot(sys.stdin.read(), args.sdk, args.current_user)
    except SnapshotRejected:
        print(
            "media permission snapshot was incomplete or ambiguous",
            file=sys.stderr,
        )
        raise SystemExit(1)
    print(" ".join(str(value) for value in snapshot))


if __name__ == "__main__":
    main()
