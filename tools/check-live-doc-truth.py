#!/usr/bin/env python3
"""Reject known-false current-state claims in DroidMatch live documentation.

This gate is intentionally selective. It binds a small set of high-risk facts
to exact required statements and narrowly scoped semantic patterns; it does not
pretend to understand every sentence in the repository.

中文：该门禁只守护少量高风险当前事实，并不声称能自动理解全部文档语义。
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys


LIVE_DOCS = (
    "README.md",
    "android/README.md",
    "mac/README.md",
    "docs/m1-status.md",
    "docs/m1-status-zh.md",
    "docs/m1-testing-guide.md",
    "docs/m1-testing-guide-zh.md",
    "docs/developer-onboarding.md",
    "docs/developer-onboarding-zh.md",
    "docs/mac-code-overview.md",
    "docs/android-code-overview.md",
    "docs/protocol-runtime.md",
    "docs/path-model.md",
    "docs/m1-device-matrix.md",
    "docs/technical-debt.md",
    "docs/pairing-auth-design.md",
)

REQUIRED_LIVE_DOC_FACTS = {
    "README.md": (
        "Slot C 产品认证/传输已有归档真机证据",
    ),
    "android/README.md": (
        "Slot C 已归档 `--dual-download-check` 与混合方向真机结果",
    ),
    "mac/README.md": (
        "协议已有 SAF delete mutation",
    ),
    "docs/m1-status.md": (
        "archived Slot C physical-device results",
        "The only open ADB M1 blockers are Slot A current-candidate release throughput",
    ),
    "docs/m1-status-zh.md": (
        "Slot C 归档真机结果",
        "当前开放的 ADB M1 阻塞项只有两类",
    ),
    "docs/path-model.md": (
        "upload derives a hidden sibling document from the stable transfer ID.",
        "Android must truncate it to that acknowledged offset before replay",
    ),
    "docs/m1-device-matrix.md": (
        "M1 validates the enabled paired Mac product path",
        "direct-root single-file SAF targets through a fresh authenticated `delete-path` session",
        "That promotion gate is separate and does not block completion of the current ADB M1 path.",
    ),
}

FORBIDDEN_STALE_CLAIMS = (
    "A future app/harness still needs to supply its owned storage URL",
    "Integrate the persistent queue into the app target",
    "synchronous transfer evidence probes and concentrated ownership remain",
    "UI transfer-queue integration remain open",
    "把 Presentation model 装配进现有视觉 app target",
    "Physical-device product-auth/transfer/revocation and sandbox file-transfer evidence",
    "sandbox file-transfer evidence, and physical product-auth/transfer evidence remain",
    "仍缺产品认证/传输与 sandbox 文件传输证据",
    "USB unplug during upload/download",
    "上传/下载期间 USB 拔插",
    "sandbox 产品传输与产品上传证据",
    "Run and archive `--dual-download-check` on the required device slots",
    "在所需设备槽位运行并归档 `--dual-download-check`",
    "把持久化队列装配进 app target（M1 后）",
    "真机配对/重连证据仍待归档",
    "sandbox 文件传输仍待验证",
    "尚未完成的是 sandbox 产品认证/文件传输与混合流真机证据",
    "but no archived physical-device result yet",
    "product-auth evidence remain open",
    "新增认证 App 配对/重连/下载路径的归档真机证据",
    "Keystore 真机证据仍待归档",
    "No device pass is claimed yet",
    "Flyme currently rejects its test APK",
    "尚未声称真机通过",
    "Flyme 当前以 `INSTALL_FAILED_USER_RESTRICTED` 拒绝测试 APK",
    "Real-device Keychain/Keystore/reconnect evidence remains open",
    "Sandbox file transfer, archived product-auth/transfer",
    "Archived physical dual/mixed evidence",
    "尚缺归档双流/混合流真机证据",
    "M1 still requires archived product-auth/file-transfer evidence",
    "发布声明前仍需归档产品认证/文件传输证据",
    "仍缺归档真机 App 配对/重连/传输与 sandbox 文件访问证据",
    "❌ **缺失：** 下载期间物理拔线",
    "记录 MEIZU M20 Slot C 下载期间的物理 USB 拔线",
    "未来 app/harness 仍需提供自己拥有的存储 URL",
    "Product authentication/transfers and mixed-stream behavior still lack archived physical-device App evidence",
    "A sandbox-entitled bundle still needs end-to-end verification",
    "a sandbox-entitled bundle still requires end-to-end verification",
    "Sandbox-entitled execution still requires end-to-end verification",
    "下一步是双/混合流与 sandbox 产品队列真机归档",
    "产品路径的真机认证/传输证据仍未完成",
    "但尚无归档设备结果",
    "但尚无归档真机结果",
    "SAF upload smoke 不自动清理，因为当前协议还没有 delete/mutation 路径",
    "before authenticated product-session workflows are enabled",
    "until protocol-level delete/mutation support exists",
    "resume is out of scope until Android can persist and validate provider partial",
    "partial 文档存在且长度等于 requested offset 时接受",
    "partial size that equals `requested_offset_bytes`",
    "hidden partial document length matches offset",
    "hidden partial document exists and length equals requested offset",
    "Android checks partial file exists and length matches",
    "SAF still requires exact remote partial length because portable rollback is unavailable",
    "SAF upload still requires exact partial length on resume",
    "216 Swift tests",
    "218 Swift tests",
    "220 Swift tests",
    "221 Swift tests",
    "222 Swift tests",
    "223 Swift tests",
    "224 Swift tests",
    "225 Swift tests",
    "129 Android unit tests",
    "scheduler actor is now 774 lines",
)


@dataclass(frozen=True)
class StaleClaimPattern:
    name: str
    expression: re.Pattern[str]


# Exact-string guards remain useful for retired wording. These bounded patterns
# additionally catch the same false current-state claims after line wrapping or
# light paraphrasing, without rejecting historical evidence descriptions.
FORBIDDEN_STALE_PATTERNS = (
    StaleClaimPattern(
        "SAF resume described as requiring an exact remote partial",
        re.compile(
            r"\bSAF\b.{0,100}\b(?:still\s+)?(?:needs?|requires?)\b"
            r".{0,60}\bexact remote partial\b",
            re.IGNORECASE | re.DOTALL,
        ),
    ),
    StaleClaimPattern(
        "SAF upload cleanup described as unsupported pending delete/mutation",
        re.compile(
            r"(?im)^(?=[^\n]*(?:\bSAF(?: upload)? cleanup\b|"
            r"\bcleanup (?:of|for) SAF(?: upload)?\b))"
            r"(?=[^\n]*\b(?:unsupported|not supported|cannot)\b)"
            r"(?=[^\n]*(?:delete|mutation))[^\n]+$",
        ),
    ),
    StaleClaimPattern(
        "archived physical download unplug listed as pending",
        re.compile(
            r"(?im)^-\s+(?:real-device\s+)?(?:physical\s+)?"
            r"USB unplug during (?:a\s+)?download\.\s*$",
        ),
    ),
    StaleClaimPattern(
        "archived source-change resume evidence listed as pending",
        re.compile(
            r"(?im)^-\s+Real-device source "
            r"(?:deletion|modification|mutation|replacement) before resume\.\s*$",
        ),
    ),
)


def _summary(text: str) -> str:
    return " ".join(text.split())[:180]


def find_stale_claims(text: str) -> list[str]:
    """Return stable descriptions of known-false claims found in one document."""
    failures = [
        f"exact stale claim: {claim}"
        for claim in FORBIDDEN_STALE_CLAIMS
        if claim in text
    ]
    for pattern in FORBIDDEN_STALE_PATTERNS:
        match = pattern.expression.search(text)
        if match is not None:
            failures.append(f"{pattern.name}: {_summary(match.group(0))}")
    return failures


def validate_live_docs(root: Path) -> list[str]:
    """Validate required facts and stale-claim policy below ``root``."""
    failures: list[str] = []
    contents: dict[str, str] = {}
    for relative_path in LIVE_DOCS:
        path = root / relative_path
        if not path.is_file():
            failures.append(f"missing live document: {relative_path}")
            continue
        contents[relative_path] = path.read_text(encoding="utf-8")

    for relative_path, text in contents.items():
        for failure in find_stale_claims(text):
            failures.append(f"{relative_path} contains {failure}")

    for relative_path, required_facts in REQUIRED_LIVE_DOC_FACTS.items():
        text = contents.get(relative_path)
        if text is None:
            continue
        for required_fact in required_facts:
            if required_fact not in text:
                failures.append(
                    f"{relative_path} is missing current product fact: {required_fact}"
                )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root to validate (defaults to this script's repository).",
    )
    args = parser.parse_args()
    failures = validate_live_docs(args.root.resolve())
    if failures:
        for failure in failures:
            print(f"live-doc truth check failed: {failure}", file=sys.stderr)
        return 1
    print("Live-document truth check passed.")
    print("中文：活文档当前事实检查通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
