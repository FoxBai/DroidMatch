# CI/CD Gates

This document records the automated and local gates that keep DroidMatch's M1
harness reproducible.

本文记录 DroidMatch M1 harness 的自动化与本地校验流程，目标是让每次改动都能复现、能诊断。

## Current CI

GitHub Actions runs `.github/workflows/m0.yml` on push, pull request, and manual
dispatch. The workflow intentionally validates host-buildable gates only; real
device smoke tests stay in the manual M1 matrix because they require physical
Android devices.

GitHub Actions 会在 push、pull request 和手动触发时运行 `.github/workflows/m0.yml`。当前 CI
只覆盖可在托管 runner 上稳定复现的 gate；真机 smoke 仍属于手动 M1 设备矩阵，因为它依赖物理 Android 设备。

| Job | Runner | Gate | Purpose |
|---|---|---|---|
| `spec` | `ubuntu-latest` | `tools/check-env.sh --proto`, `tools/check-m0.sh`, `tools/check-source-size.py`, `tools/check-proto.sh`, `tools/check-doc-links.py`, `tools/check-m1-run-logs.sh` | Validate spec closure, source-size debt ceilings, protobuf schemas, documentation links, and redacted fixture logs. |
| `mac-skeleton` | `macos-26` | `tools/check-env.sh --swift`, `tools/run-swift-tests.sh` | Validate Swift Core, presentation binding, harness, and Swift Testing availability on the current GA arm64 macOS image. |
| `android-skeleton` | `ubuntu-latest` | JDK 17, Android platform 35, `tools/check-env.sh --android`, `tools/check-m1-skeleton.sh` | Validate Android unit tests, app/test APK compilation, lint, and launcher manifest checks; it does not claim device execution. |

| Job | 运行环境 | Gate | 目的 |
|---|---|---|---|
| `spec` | `ubuntu-latest` | `tools/check-env.sh --proto`, `tools/check-m0.sh`, `tools/check-source-size.py`, `tools/check-proto.sh`, `tools/check-doc-links.py`, `tools/check-m1-run-logs.sh` | 验证规格收口、源码规模债务上限、protobuf schema、文档链接和脱敏后的 fixture 日志。 |
| `mac-skeleton` | `macos-26` | `tools/check-env.sh --swift`、`tools/run-swift-tests.sh` | 在当前 GA 的 arm64 macOS 镜像上验证 Swift Core、presentation 绑定和 harness，并确认 Swift Testing 可用。 |
| `android-skeleton` | `ubuntu-latest` | JDK 17、Android platform 35、`tools/check-env.sh --android`、`tools/check-m1-skeleton.sh` | 验证 Android 单测、app/test APK 编译、lint 和 launcher manifest；不声称已执行真机测试。 |

## Local Gates

Run the environment preflight before the full gates when setting up a new
machine:

新机器或新 runner 先跑环境 preflight，再跑完整 gate：

```text
bash tools/check-env.sh --all
```

The normal local verification set is:

常规本地验证命令：

```text
bash tools/check-m0.sh
python3 tools/check-source-size.py
bash tools/check-proto.sh
python3 tools/check-doc-links.py
bash tools/check-m1-run-logs.sh
bash tools/check-m1-skeleton.sh
```

Mac-only changes may run the narrower Swift gate:

只改 Mac 端时可以跑较窄的 Swift gate：

```text
bash tools/check-env.sh --swift
bash tools/run-swift-tests.sh
```

Android-only changes may skip Swift and run the Gradle-backed gate:

只改 Android 端时可以跳过 Swift，并运行 Gradle gate：

```text
DROIDMATCH_SKIP_SWIFT=1 bash tools/check-m1-skeleton.sh
```

`check-m1-skeleton.sh` also syntax-checks the physical-device smoke script and
requires its help to expose the opt-in dual-download and mixed-direction flags.
This guards the evidence entry points only; it does not execute or claim a device run.

It also runs `check-source-size.py`. New handwritten production sources have a
1,000-line ceiling; two documented legacy monolith ceilings can only move down.
This is a regression guard, while [Structural Debt Baseline](technical-debt.md)
owns the actual decomposition plan.

`check-m1-skeleton.sh` 还会检查真机 smoke 脚本语法，并要求帮助文本暴露显式启用的
双下载与混合方向参数。该 gate 只防止证据入口腐化，不会执行或声称真机运行。

## Known Host Requirements

- Protobuf schema checks require `protoc`.
- Documentation link checks require Python 3 and validate local Markdown link
  targets only; external URLs remain outside CI to avoid flaky network gates.
- Mac tests use Swift Testing macros. `tools/run-swift-tests.sh` first tries the
  selected toolchain directly, then falls back to explicit Xcode or Command Line
  Tools `Testing.framework`, macro plugin, and runtime rpath settings when
  available. If a CLT update cannot load the default arm64 standard library but
  an explicit arm64e probe succeeds, the script also selects an arm64e test
  triple; healthy default targets and CI are unchanged. The macOS CI job uses
  `macos-26`, the current GA arm64 runner with
  Xcode 26 images, so Swift Testing is not tied to older `macos-15` defaults.
- Android gates require JDK 17, Android SDK platform 35, build-tools with
  `aapt`, and the checked-in `android/gradlew` wrapper or `DROIDMATCH_GRADLE`.
- AndroidX Test runner 1.7.0 and ext.junit 1.3.0 compile the isolated Keystore
  instrumentation APK. `connectedDebugAndroidTest` remains an explicit device
  action and is not part of hosted CI.

- Protobuf schema 检查需要 `protoc`。
- 文档链接检查需要 Python 3，只校验本地 Markdown 链接目标；外部 URL 不放入 CI，
  避免网络波动导致 gate 不稳定。
- Mac 测试使用 Swift Testing 宏。`tools/run-swift-tests.sh` 会先尝试当前 toolchain 的默认路径，
  然后回退到 Xcode 或 Command Line Tools 里的显式 `Testing.framework`、宏插件和运行时 rpath；
  若 CLT 更新导致默认 arm64 标准库不可加载、但 arm64e 探针成功，脚本才会额外选择 arm64e test triple，正常 CI 路径不变。
  macOS CI job 使用当前 GA 的 arm64 `macos-26` runner，内置 Xcode 26 镜像，避免依赖较旧的
  `macos-15` 默认 Xcode 配置。
- Android gate 需要 JDK 17、Android SDK platform 35、包含 `aapt` 的 build-tools，以及仓库内
  `android/gradlew` 或 `DROIDMATCH_GRADLE`。
- AndroidX Test runner 1.7.0 与 ext.junit 1.3.0 用于编译隔离的 Keystore
  instrumentation APK；`connectedDebugAndroidTest` 仍是显式真机动作，不进入托管 CI。

## Device Matrix

M1 real-device runs are not CI jobs. Record them with
`tools/run-m1-device-smoke.sh`, then commit the redacted logs under
`fixtures/m1-runs/` when they prove a new matrix case.

M1 真机运行不是 CI job。使用 `tools/run-m1-device-smoke.sh` 记录结果；当日志证明新的设备矩阵场景时，把脱敏日志提交到
`fixtures/m1-runs/`。

## CD Status

Continuous delivery is intentionally not active yet. Release automation should
wait until M1 passes the required ADB device matrix and the product has a signed
macOS app target. The future release workflow should include signing,
notarization, DMG packaging, checksum generation, and release-note validation.

当前还没有启用持续交付。发布自动化应等待 M1 通过要求的 ADB 设备矩阵，并且产品具备已签名的 macOS app
target。未来 release workflow 应包含签名、公证、DMG 打包、checksum 生成和 release note 校验。
