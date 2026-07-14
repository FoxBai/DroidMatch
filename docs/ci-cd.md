# CI/CD Gates

This document records the automated and local gates that keep DroidMatch's M1
harness reproducible.

本文记录 DroidMatch M1 harness 的自动化与本地校验流程，目标是让每次改动都能复现、能诊断。

## Current CI

GitHub Actions runs `.github/workflows/m0.yml` for pull requests, pushes to
`main`, and manual dispatch. Topic-branch pushes are intentionally omitted
because the pull-request event already validates the same head commit; this
avoids duplicate macOS/Android jobs while `main` still receives a post-merge
regression run. The workflow validates host-buildable gates only; real device
smoke tests stay in the manual M1 matrix because they require physical Android
devices.

GitHub Actions 会在 pull request、`main` push 和手动触发时运行
`.github/workflows/m0.yml`。topic branch 不再重复触发 push 流程，因为同一 head
commit 已由 PR 事件验证；`main` 合并后仍会执行回归门禁。当前 CI 只覆盖可在托管
runner 上稳定复现的 gate；真机 smoke 仍属于手动 M1 设备矩阵，因为它依赖物理 Android 设备。

| Job | Runner | Gate | Purpose |
|---|---|---|---|
| `spec` | `ubuntu-latest` | `tools/check-env.sh --proto`, `tools/check-m0.sh`, `tools/check-source-size.py`, `tools/check-proto.sh`, `tools/check-doc-links.py`, `tools/check-m1-run-logs.sh` | Validate spec closure, bilingual resource parity/format placeholders, source-size debt ceilings, protobuf schemas, documentation links, and redacted fixture logs. |
| `mac-skeleton` | `macos-26` | Swift gates, ordinary/sandbox release App assembly, local DMG mount verification | Validate Swift products and the sandboxed distribution shape. A toolchain- and lockfile-bound cache stores only the dedicated SwiftPM scratch directory; assembled Apps, signatures, embedded adb, and DMGs stay outside it. The bundle verifier checks metadata, resources, privacy manifests, signatures, exact entitlements, embedded adb, and NOTICE. The DMG gate checks integrity, Applications link, SHA-256 generation, read-only mounting, and the mounted App boundary. CI does not claim USB hardware execution, Developer ID signing, or notarization. |
| `android-skeleton` | `ubuntu-latest` | JDK 17, Android platform 35, `tools/check-env.sh --android`, `tools/check-m1-skeleton.sh` | Validate Android unit tests, app/test APK compilation, lint, and launcher manifest checks; it does not claim device execution. |

The M0 contract also runs `tools/check-no-external-model-workflow.py`. It scans
tracked text for the retired provider-specific orchestration vocabulary, while
leaving ordinary runtime dependency notices and the platform's own model/data
terminology untouched. This is a repository-hygiene guard, not a claim about
which assistant is used for an individual engineering session.

Release assembly also freezes runtime-license attribution. The Mac bundle ships
SwiftProtobuf 1.38.1's Apache-2.0 text under `Contents/Resources/Legal`; the
Android APK ships protobuf-javalite 4.35.1's BSD-3-Clause text under `assets/`.
Verifiers require the platform-specific notice and reviewed license files.
Android Gradle additionally applies strict SHA-256 dependency verification to
plugins, metadata, build tools, runtime, and test artifacts. The committed
baseline was bootstrapped from the configured Google/Maven Central repositories
and prevents later byte drift; it is integrity/TOFU evidence, not publisher
signature provenance.
Every remote GitHub Action is pinned to a full 40-character commit SHA rather
than a mutable major tag. A trailing version comment keeps upgrades readable;
`tools/check-ci-action-pins.py` rejects any new tag/branch reference.

| Job | 运行环境 | Gate | 目的 |
|---|---|---|---|
| `spec` | `ubuntu-latest` | `tools/check-env.sh --proto`, `tools/check-m0.sh`, `tools/check-source-size.py`, `tools/check-proto.sh`, `tools/check-doc-links.py`, `tools/check-m1-run-logs.sh` | 验证规格收口、双语资源键/格式占位符、源码规模债务上限、protobuf schema、文档链接和脱敏后的 fixture 日志。 |
| `mac-skeleton` | `macos-26` | Swift 门禁、普通/sandbox release App 组装、本地 DMG 挂载验证 | 验证 Swift 产品及 sandbox 分发形态；仅缓存与 toolchain/lockfile 绑定的独立 SwiftPM scratch 目录，组装 App、签名、内置 adb 和 DMG 均不进入缓存；bundle verifier 检查 metadata、资源、隐私清单、签名、精确 entitlement、内置 adb 与 NOTICE；DMG gate 检查完整性、Applications 快捷方式、SHA-256、只读挂载和挂载后 App 边界。CI 不声称执行 USB 真机、Developer ID 签名或公证。 |
| `android-skeleton` | `ubuntu-latest` | JDK 17、Android platform 35、`tools/check-env.sh --android`、`tools/check-m1-skeleton.sh` | 验证 Android 单测、app/test APK 编译、lint 和 launcher manifest；不声称已执行真机测试。 |

M0 合同还会运行 `tools/check-no-external-model-workflow.py`。它扫描已跟踪文本，防止
已退役的 provider 专属编排术语重新出现，同时不干扰普通运行时依赖 notice 或平台自身的
model/data 术语。这是仓库卫生门禁，不代表某次工程会话使用了哪一种助手。

release 组装也会固定运行时许可归档：Mac bundle 在
`Contents/Resources/Legal` 携带 SwiftProtobuf 1.38.1 的 Apache-2.0 文本；
Android APK 在 `assets/` 携带 protobuf-javalite 4.35.1 的 BSD-3-Clause 文本。
verifier 要求平台对应的 notice 和经审查的许可证文件。
Android Gradle 还会对插件、metadata、构建工具、runtime 与测试 artifact 执行 strict
SHA-256 dependency verification。已提交基线来自配置的 Google/Maven Central 仓库，
用于阻止后续字节漂移；它属于 integrity/TOFU 证据，不代表发布者签名来源认证。
所有远程 GitHub Action 都固定为 40 位完整 commit SHA，而不是可移动 major tag；
行尾版本注释保留可读升级线索，`tools/check-ci-action-pins.py` 会拒绝新增 tag/branch 引用。

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

`tools/check-release-readiness.sh --github` is stricter than checking whether
`main` has any protection object. It requires the observed Phase A controls:
strict up-to-date `spec`/`mac-skeleton`/`android-skeleton` checks, PR workflow
with zero approvals while there is no independent maintainer, conversation
resolution, linear history, administrator enforcement, and disabled force-push
and deletion. The local `HEAD` must also equal the live GitHub `main` tip before
its exact-commit hosted run can pass. A stale commit, unreadable main tip, or
readable but weaker policy is a release blocker.

The same preflight also checks repository-level baseline settings recorded in
`docs/github-governance.md`: `main` is the default branch, merged topic
branches are deleted automatically, squash is the only merge mode, and Secret
Scanning plus push protection are enabled. These checks catch a hosting-policy
regression that branch protection alone would not reveal.

`tools/check-release-readiness.sh --github` 不只检查 `main` 是否存在任意保护对象；
它会核验 Phase A 的具体控制：严格要求最新分支上的三项 hosted checks、当前单维护者
阶段的零审批 PR 流程、会话解决、线性历史、管理员约束，以及禁用 force-push/删除。
本地 `HEAD` 还必须等于 GitHub 上实时的 `main` tip，随后才核验该精确提交的 hosted
run。旧提交、不可读的 main tip 或 API 可读但策略更弱时都会阻止发布声明。

同一预检还会核验 `docs/github-governance.md` 记录的仓库级基线：`main` 是默认分支，
合并后的主题分支自动删除，只允许 squash 合并，并且 Secret Scanning 与推送保护已开启。
这些检查能发现仅检查分支保护时遗漏的托管策略回归。

Mac-only changes may run the narrower Swift gate:

只改 Mac 端时可以跑较窄的 Swift gate：

```text
bash tools/check-env.sh --swift
bash tools/run-swift-tests.sh
tools/build-mac-app.sh
```

Android-only changes may skip Swift and run the Gradle-backed gate:

只改 Android 端时可以跳过 Swift，并运行 Gradle gate：

```text
DROIDMATCH_SKIP_SWIFT=1 bash tools/check-m1-skeleton.sh
```

`check-m1-skeleton.sh` also syntax-checks the physical-device smoke script and
requires its help to expose the opt-in dual-download and mixed-direction flags.
This guards the evidence entry points only; it does not execute or claim a device run.

It also runs `check-source-size.py`. Handwritten production, unit-test, and
instrumentation-test sources share an 800-line ceiling with no legacy
exceptions.
This is a regression guard, while [Structural Debt Baseline](technical-debt.md)
owns the actual decomposition plan.

`check-m0.sh` also runs `check-localizations.py`. It rejects missing, extra,
duplicate, or empty Mac/Android translations and mismatched printf argument
types while allowing translated text to reorder positional arguments. Every
literal `AppStrings.value` key must exist in both Mac catalogs, and every Mac
catalog entry must still be referenced, preventing silent key fallback and stale
translation accumulation. Android Java/manifest references and catalog entries
must likewise match exactly; framework-owned `android.R.string` values are outside
the app catalog and intentionally ignored.

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
- Local app assembly additionally uses standard macOS `sips`, `iconutil`,
  `plutil`, and `codesign`; it applies only an ad-hoc signature.
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
- 本地 App 组装还使用 macOS 标准工具 `sips`、`iconutil`、`plutil` 和 `codesign`，且只执行 ad-hoc 签名。
- Android gate 需要 JDK 17、Android SDK platform 35、包含 `aapt` 的 build-tools，以及仓库内
  `android/gradlew` 或 `DROIDMATCH_GRADLE`。
- AndroidX Test runner 1.7.0 与 ext.junit 1.3.0 用于编译隔离的 Keystore
  instrumentation APK；`connectedDebugAndroidTest` 仍是显式真机动作，不进入托管 CI。

## Device Matrix

M1 real-device runs are not CI jobs. Record them with
`tools/run-m1-device-smoke.sh`, then commit the redacted logs under
`fixtures/m1-runs/` when they prove a new matrix case. The current-tip Slot A
throughput gate instead uses `tools/run-m1-throughput-gate.sh`, whose
`m1-adb-throughput-v1` log is published only after strict provenance, exact
transfer, negotiated-chunk, privacy, cleanup, staged-profile, and no-clobber
publication validation. Evidence privacy rejection never echoes the matching line.
Attended product insertion uses a separate `m1-product-usb-insertion-v1` fixture
directory and validator. CI exercises its AX policy, countdown state machine,
artifact metadata, privacy/schema rejection, and zero-log count; CI cannot replace
the physical cable action or the operator's post-run attestation.

M1 真机运行不是 CI job。使用 `tools/run-m1-device-smoke.sh` 记录结果；当日志证明新的设备矩阵场景时，把脱敏日志提交到
`fixtures/m1-runs/`。current-tip Slot A 吞吐 gate 则使用
`tools/run-m1-throughput-gate.sh`；只有 provenance、精确传输、实际协商 chunk、
隐私、清理、staged profile 与 no-clobber 发布严格验证完成后，才发布
`m1-adb-throughput-v1` 日志；隐私拒绝不会回显命中的原文行。
人工产品插入使用独立的 `m1-product-usb-insertion-v1` fixture 目录与校验器。CI 会覆盖
AX policy、倒计时状态机、artifact metadata、隐私/结构拒绝和零日志计数，但不能替代
真实插线动作与操作者事后确认。

## CD Status

Continuous delivery is intentionally not active yet. Release automation should
wait until M1 passes the required ADB device matrix and the product has a signed
macOS app target. CI now compiles the SwiftUI product and assembles/strictly
verifies ad-hoc local `.app` and mounted `.dmg` artifacts; this is build
evidence, not release signing. The future release workflow should replace the
ad-hoc identity with Developer ID signing, submit/staple notarization, publish
the checksum, and validate release notes.

当前还没有启用持续交付。发布自动化应等待 M1 通过要求的 ADB 设备矩阵，并且产品具备已签名的 macOS app
target。CI 现已编译 SwiftUI 产品并严格校验 ad-hoc 本地 `.app` 与挂载后的 `.dmg`；这只是构建证据，不是发布签名。
未来 release workflow 应把 ad-hoc 身份替换为 Developer ID 签名，提交并 stapled 公证，发布 checksum，并校验 release note。
