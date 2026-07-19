# CI/CD Gates

This document records the automated and local gates that keep DroidMatch's M1
harness reproducible.

本文记录 DroidMatch M1 harness 的自动化与本地校验流程，目标是让每次改动都能复现、能诊断。

## Current CI

GitHub Actions runs `.github/workflows/m0.yml` for pull requests, pushes to
`main`, the dedicated `codex/main-gate/**` owner-integration refs, and manual
dispatch. Other topic-branch pushes are intentionally omitted because the
pull-request event already validates the same head commit. The dedicated gate
ref is the exception that lets an exact candidate SHA earn protection-eligible
checks before a no-PR fast-forward; `main` still receives the authoritative
post-integration regression run. The workflow validates host-buildable gates
only; real device smoke tests stay in the manual M1 matrix because they require
physical Android devices.

GitHub Actions 会在 pull request、`main` push、专用 `codex/main-gate/**` 所有者集成
ref 的 push 和手动触发时运行 `.github/workflows/m0.yml`。其他 topic branch 不重复
触发 push；专用 gate ref 是例外，用于让无 PR 快进前的精确候选 SHA 获得保护层认可的
检查，最终 `main` push 仍会执行具有权威性的回归门禁。当前 CI 只覆盖可在托管 runner
上稳定复现的 gate；真机 smoke 仍属于手动 M1 设备矩阵，因为它依赖物理 Android 设备。

| Job | Runner | Gate | Purpose |
|---|---|---|---|
| `spec` | `ubuntu-latest` | `tools/check-env.sh --proto`, `tools/check-m0.sh`, `tools/check-source-size.py`, `tools/check-proto.sh`, `tools/check-doc-links.py`, `tools/check-m1-run-logs.sh` | Validate spec closure, selected code-to-live-document capability facts, bilingual resource parity/format placeholders, source-size debt ceilings, protobuf schemas, documentation links, and redacted fixture logs. |
| `mac-skeleton` | `macos-26` | Swift gates, ordinary/sandbox release App assembly, local DMG mount verification | Validate Swift products and the sandboxed distribution shape. A toolchain- and lockfile-bound cache stores only the dedicated SwiftPM scratch directory; assembled Apps, signatures, embedded adb, and DMGs stay outside it. A valid embedded adb vendor signature is preserved; only a genuinely unsigned custom adb is signed locally, while an invalid existing signature is rejected. The outer App receives the local ad-hoc identity and binds the exact adb bytes in its resource seal. Before reading metadata/resources, the bundle verifier requires the current static tree to contain only owner-readable/traversable real directories and owner-readable single-link regular files with no special or group/world-write bits; symlinks and every other filesystem node are rejected, and traversal errors fail closed. It then requires the signed versioned device-name JSON, validates its exact schema, bounds, field types, and credential-free HTTPS source URLs, and checks privacy manifests, signatures, exact entitlements, embedded adb, and NOTICE. Candidate validation defers only the private-transaction-path `adb version`; after atomic publication the final path receives the complete verifier before completion, with replacement rollback or first-publication withdrawal on failure. Sandbox call-order/signature regressions and the full hard-kill recovery state matrix are offline-gated. The DMG gate checks integrity, Applications link, SHA-256 generation, read-only mounting, and the mounted App boundary. `hdiutil verify` may retry twice only for its exact transient resource-unavailable condition. Published and mounted-App verification may also retry twice only for the exact `embedded adb is not runnable` result; every attempt retains the full boundary check. Malformed images, every other error, and retry exhaustion still fail immediately. CI does not claim USB hardware execution, Developer ID signing, or notarization. |
| `android-skeleton` | `ubuntu-latest` | JDK 17, Android platform 36 / Build Tools 36.0.0, `tools/check-env.sh --android`, `tools/check-m1-skeleton.sh` | Validate Android unit tests, app/test APK compilation, lint, and launcher manifest checks; it does not claim device execution. |

`tools/check-live-doc-truth.py` owns the selective current-state documentation
contract inside the spec gate. It requires a small set of high-risk facts and
rejects both retired exact wording and narrowly bounded paraphrases of known-false
SAF resume/cleanup or archived-device-evidence claims. Its focused test proves
the accepted and rejected forms plus missing-document/current-fact behavior.
`tools/check-maintainer-contract.py` separately binds those capability claims to
implementation seams. Neither check replaces human semantic review.

Both `tools/check-m0.sh` and `tools/check-m1-skeleton.sh` run
`tools/check-media-upload-contract.py`, which compares the Swift and Java image
and video extension allowlists and keeps an unsupported `.ts` upload rejected.
They also run the portable running-App publication regression; the mac-skeleton
execution exercises native `proc_pidpath` plus `KERN_PROCARGS2` behavior, including
rename/replacement/unlink after process launch.

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
| `spec` | `ubuntu-latest` | `tools/check-env.sh --proto`, `tools/check-m0.sh`, `tools/check-source-size.py`, `tools/check-proto.sh`, `tools/check-doc-links.py`, `tools/check-m1-run-logs.sh` | 验证规格收口、选定代码能力与活文档事实绑定、双语资源键/格式占位符、源码规模债务上限、protobuf schema、文档链接和脱敏后的 fixture 日志。 |
| `mac-skeleton` | `macos-26` | Swift 门禁、普通/sandbox release App 组装、本地 DMG 挂载验证 | 验证 Swift 产品及 sandbox 分发形态；仅缓存与 toolchain/lockfile 绑定的独立 SwiftPM scratch 目录，组装 App、签名、内置 adb 和 DMG 均不进入缓存。有效的内置 adb 厂商签名会保留；只有完全未签名的自定义 adb 才补本地签名，已有但无效的签名直接拒绝。外层 App 使用本地 ad-hoc 身份并由 resource seal 绑定 adb 精确字节。bundle verifier 会在读取 metadata/资源前要求当前静态树只含 owner 可读/可遍历的真实目录和 owner 可读的单链接普通文件，禁止特殊权限位、group/world-write、symlink 及其他节点，遍历错误也 fail closed。随后要求随签名封装的版本化机型名 JSON，校验其精确 schema、上限、字段类型和无凭据 HTTPS 来源，再检查隐私清单、签名、精确 entitlement、内置 adb 与 NOTICE。候选阶段只延后私有事务路径中的 `adb version`；原子发布后最终路径会在标记完成前执行完整 verifier，失败时替换发布恢复旧 App，首次发布则撤回。sandbox 调用顺序/签名分支与完整 hard-kill recovery state 矩阵均纳入离线门禁。DMG gate 检查完整性、Applications 快捷方式、SHA-256、只读挂载和挂载后 App 边界。`hdiutil verify` 仅对明确的临时资源不可用最多额外重试两次；已发布与挂载 App verifier 也只在精确返回 `embedded adb is not runnable` 时最多额外重试两次，每次都保留完整边界检查。坏镜像、其他错误和重试耗尽仍立即失败。CI 不声称执行 USB 真机、Developer ID 签名或公证。 |
| `android-skeleton` | `ubuntu-latest` | JDK 17、Android platform 36 / Build Tools 36.0.0、`tools/check-env.sh --android`、`tools/check-m1-skeleton.sh` | 验证 Android 单测、app/test APK 编译、lint 和 launcher manifest；不声称已执行真机测试。 |

spec gate 中的 `tools/check-live-doc-truth.py` 独立拥有选择性的活文档当前事实契约：
它要求少量高风险事实存在，同时拒绝已退役原句，以及对 SAF 续传/清理或已归档真机证据
的窄范围错误改写。聚焦测试覆盖接受/拒绝样例、缺失文档和缺失当前事实；
`tools/check-maintainer-contract.py` 则继续把这些能力声明绑定到实现接缝。两者都不能替代
人工语义审查。

`tools/check-m0.sh` 与 `tools/check-m1-skeleton.sh` 都会运行
`tools/check-media-upload-contract.py`，逐项比较 Swift/Java 的图片与视频扩展名
allowlist，并锁定不受支持的 `.ts` 上传必须被拒绝。
两者也运行可移植的运行中 App 发布回归；mac-skeleton 会实际覆盖 macOS 原生
`proc_pidpath` 与 `KERN_PROCARGS2` 行为，包括进程启动后的 rename、替换和 unlink。

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
strict up-to-date `spec`/`mac-skeleton`/`android-skeleton` checks, no required-PR
rule under the owner's direct-integration decision, conversation resolution for
optional PRs, linear history, administrator enforcement, and disabled force-push
and deletion. The local `HEAD` must equal the live GitHub `main` tip, and only a
successful `push` event on branch `main` for that exact SHA counts as hosted
release evidence. The script re-reads the live tip after its GitHub queries and
also re-reads local HEAD plus worktree status after every slow artifact/hosting
check, so a concurrent remote advance or local source mutation fails closed. A
stale commit, PR/manual run, unreadable tip, changing tip/local snapshot, or
readable but weaker policy is a release blocker.

With `--artifact`, the same preflight verifies the complete deep/strict code
seal, the sandbox product bundle boundary, and the notarization staple. It also
requires the embedded source revision to equal the exact local HEAD, the
source-dirty marker to be false, and the build configuration to be `release`.
Tool details that can contain certificate subjects or local artifact paths are
withheld on failure.

The same preflight also checks repository-level baseline settings recorded in
`docs/github-governance.md`: `main` is the default branch, merged topic
branches are deleted automatically, squash is the only merge mode, and Secret
Scanning plus push protection are enabled. These checks catch a hosting-policy
regression that branch protection alone would not reveal.

`tools/check-release-readiness.sh --github` 不只检查 `main` 是否存在任意保护对象；
它会核验 Phase A 的具体控制：严格要求最新分支上的三项 hosted checks、当前单维护者
直推决策下不设置强制 PR、可选 PR 的会话解决、线性历史、管理员约束，以及禁用
force-push/删除。本地 `HEAD` 必须等于 GitHub 上实时的 `main` tip，并且只有分支
`main` 上该 SHA 的成功 `push` 事件才算发布用托管证据；脚本完成 GitHub 查询后会再次
读取远端 tip，并在全部慢速产物/托管检查结束后重新读取本地 HEAD 与工作树状态。
旧提交、PR/手动 run、不可读或检查期间变化的 main tip/本地源码快照，以及 API 可读但
策略更弱时都会阻止发布声明。

传入 `--artifact` 时，同一预检还会验证完整 deep/strict 代码封印、sandbox 产品 bundle
边界与公证票据，并要求产物内嵌源码 revision 精确等于本地 HEAD、source-dirty 为 false、
构建配置为 `release`。失败时会隐去可能包含证书主体或本地产物路径的工具详情。

同一预检还会核验 `docs/github-governance.md` 记录的仓库级基线：`main` 是默认分支，
合并后的主题分支自动删除，只允许 squash 合并，并且 Secret Scanning 与推送保护已开启。
这些检查能发现仅检查分支保护时遗漏的托管策略回归。

For owner integration without a PR, use the repository-owned command below.
It requires explicit confirmation and a clean HEAD that fast-forwards the
freshly fetched live base. Before any remote push, it runs the local maintainer
contract against that candidate and rejects known test-inventory, wiring, or
takeover-document drift. It then validates Phase A, creates a unique temporary
ref, requires a `push`-event `Spec and Skeleton Gates` run with the exact
branch/SHA, re-fetches main and protection after that potentially long run,
performs a non-forced push, removes only its own temporary ref, and waits for the
second, authoritative exact-main run. The local preflight does not replace
hosted admission, and a manual `workflow_dispatch` run is deliberately rejected
as admission evidence. Each protection read retries a transport/API failure at
most three times with a bounded delay; a successfully read policy that differs
from Phase A is rejected immediately and is never retried into acceptance.

Read-only `origin/main` refreshes use the same three-attempt bounded-recovery
shape so a single transport outage after a successful push does not skip owned
ref cleanup and exact-main CI observation. Candidate creation is never retried.
After a failed main fast-forward result, the script first refreshes the exact
remote tip: it continues without another write when the candidate is already
live, retries at most three times only for an explicit transport signature while
main still equals the pre-gate base, revalidates Phase A before every extra write,
then refreshes and compares that tip again immediately before the retry. It
immediately rejects policy/auth failures or any other main tip. Cleanup may repeat
only the idempotent deletion of the script-owned unique temporary ref.

仓库所有者无 PR 集成时使用仓库自带命令。它要求显式确认和干净的可快进 HEAD，核验
候选的本地维护者契约后再核验 Phase A，在唯一临时 ref 上要求事件/分支/SHA 都精确一致
的 `push` 门禁，长时间 CI 后重新读取 main 与保护，只做非强制快进，清理自己创建的 ref，
并等待第二次、具有发布证据效力的精确 main run；本地预检只会在远端写入前拒绝已知的
测试数量、关键接线和接管文档漂移，不能替代托管准入，手动 `workflow_dispatch` 也明确
不能充当准入证据。每次保护读取
只会对传输/API 失败做最多三次有界重试；一旦成功读取到偏离 Phase A 的策略便立即拒绝，
绝不会通过重试把无效策略变成可接受状态。

只读的 `origin/main` 刷新同样最多有界重试三次，避免成功 push 后的一次网络故障跳过
自有 ref 清理和精确 main CI 观察。候选创建本身绝不重试。main 快进返回失败后，脚本会
先刷新精确远端 tip：候选已经上线时不重复写入；只有错误明确属于传输故障且 main 仍等于
门禁前基线时才最多尝试三次，并在每次额外写入前重新核验 Phase A；权限/策略拒绝或任何
其他 main tip 都立即停止。Phase A 核验后、重试紧前还会再次刷新并比较 main tip。清理
阶段只允许重复删除脚本自己创建的唯一临时 ref：

```bash
tools/push-main-with-gates.sh --confirm-direct-main
```

Exit zero means both the candidate-ref and exact-main runs passed, the remote tip
remained the candidate, and Phase A was still intact after final CI. If the base
comparison or GitHub protection rejects the push, rebuild on the new live tip
and rerun; never weaken protection as a shortcut. If the final main CI fails,
main has already advanced and the command returns non-zero: preserve the failed
run and fix forward with a new candidate instead of rewriting history.

只有候选 ref 和精确 main 两轮 CI 都通过、远端 tip 仍是候选且最终 Phase A 仍完整时，
命令才返回 0。最终 push 明确禁止 `--force`；基线变化或保护拒绝时必须基于新 tip 重建
并重跑，不能临时削弱保护。若最终 main CI 失败，main 已经前移且命令会返回非零；保留
失败证据并用新候选向前修复，不能改写历史。

Mac-only changes may run the narrower Swift gate:

只改 Mac 端时可以跑较窄的 Swift gate：

```text
bash tools/check-env.sh --swift
bash tools/run-swift-tests.sh
tools/build-mac-app.sh
```

The App builder creates a missing output parent without changing an existing
parent's permissions. In particular, it must not use `install -d` on the caller's
parent: doing so can strip sticky or shared-directory mode bits. Its transactional
offline suite holds a non-default parent mode across a successful build.

中文：App 构建器只在输出父目录缺失时创建它，不会修改既有父目录权限；禁止对调用方父目录
使用可能移除 sticky/共享目录 mode 的 `install -d`。事务离线套件会在成功构建前后复核一个
非默认父目录 mode 完全不变。

During iteration, `bash tools/run-swift-tests.sh --filter '<regex>'` keeps the
same Swift Testing framework, target, and scratch-path fallback while selecting
matching tests. A caller-supplied filter is never used by
`check-m1-skeleton.sh`; handoff and hosted gates discover the unique SwiftPM
inventory, escape each complete specifier, run exact process shards of at most
20 tests, and verify every shard's executed count. The internal filters bound
local TCP-fixture concurrency without relying on Swift Testing 1902's
experimental global-width setting, which can stall at low values.
`DROIDMATCH_SWIFT_TEST_SHARD_SIZE` may reduce the process shard size from 1
through 20. `--probe-only` and caller `--filter` are mutually exclusive, and
malformed arguments fail before launching Swift.
The Security.framework pairing-store round trip is disabled in ordinary gates;
set `DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST=1` only for an attended integration run
that is expected to access the current login Keychain. Unit coverage continues
through the injected backend, so CI and routine local checks never need a
Keychain password.

迭代时可用 `bash tools/run-swift-tests.sh --filter '<regex>'`，在保留相同 Swift
Testing framework、target 与 scratch fallback 的同时只运行匹配测试。调用方 filter
不会进入 `check-m1-skeleton.sh`；交接和托管门禁会发现唯一 SwiftPM 清单、转义完整
specifier、按默认最多 20 项运行精确进程分片，并核对每片实际执行数。内部 filter
限制本地 TCP fixture 的瞬时并发，不依赖 Swift Testing 1902 在低宽度下可能停滞的
实验全局并发设置。`DROIDMATCH_SWIFT_TEST_SHARD_SIZE` 可在 1–20 间缩小进程分片大小。
`--probe-only` 与调用方 `--filter` 互斥，缺值、重复或未知参数会在启动 Swift 前失败。
Security.framework 配对存储 round-trip 在普通门禁中默认关闭；只有明确要访问当前登录
钥匙串的有人值守集成运行才设置 `DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST=1`。单元覆盖继续
使用注入后端，因此 CI 与日常本地检查不需要钥匙串密码。

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
exceptions. Handwritten shell/Python files under `tools/` now share the same
default with no exception. The former 3,277-line physical-device orchestrator
is now a 673-line final orchestrator over explicit usage, option/validation,
device-control, privacy/evidence, App Sandbox probe, result-log, and cleanup
helpers; every helper fits the same default.
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
- Mac tests and product builds share `tools/swift-build-compat.sh`: it creates
  the stable package-local module cache, disables only SwiftPM's redundant nested
  sandbox when `CODEX_SANDBOX` already supplies the outer boundary, and selects
  arm64e only after the default target fails and the explicit fallback probe passes.
  Mac tests use Swift Testing macros. `tools/run-swift-tests.sh` first tries the
  selected toolchain directly, then falls back to explicit Xcode or Command Line
  Tools `Testing.framework`, macro plugin, and runtime rpath settings when
  available. The runner defaults to the stable, package-local ignored module
  cache `${DROIDMATCH_SWIFT_SCRATCH_PATH:-mac/.build}/droidmatch-module-cache`
  (or honors `DROIDMATCH_SWIFT_MODULE_CACHE_PATH`) instead of relying on an
  unwritable home cache or a disposable cache whose incremental links can retain
  missing PCM references. Swift Testing's dynamic macro is loaded as a library with
  `-load-plugin-library`, not as a plugin executable. The fallback is considered available only after the real probe is
  typechecked with the same framework, macro plugin, SDK, and target override;
  merely finding those files is not sufficient, so SDK/compiler mismatches fail
  during `--probe-only`. When `CODEX_SANDBOX` is present, SwiftPM also receives
  `--disable-sandbox` to avoid a failing nested `sandbox-exec`; the existing outer
  Codex sandbox remains the isolation boundary, and normal local/CI runs are
  unchanged. Each selected/full run builds the complete test bundle once, then
  uses `--skip-build` for inventory and every shard so discovery and execution
  cannot silently relink different bytes. Those prepared invocations run in a
  60-second process-group boundary: a macOS developer-tool/dyld policy stall
  terminates all descendants with exit 124 and an actionable diagnostic instead
  of waiting indefinitely. Complete runs explicitly clear
  `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` and use exact process shards;
  the inventory must be nonempty and unique, and each shard's top-level Swift
  Testing count must match its selected specifiers. If a CLT update cannot load
  the default arm64 standard library but
  an explicit arm64e probe succeeds, the script also selects an arm64e test
  triple; healthy default targets and CI are unchanged. The macOS CI job uses
  `macos-26`, the current GA arm64 runner with
  Xcode 26 images, so Swift Testing is not tied to older `macos-15` defaults.
- Local app assembly uses macOS `sips` for ten exact PNG renditions, a strict
  standard-library-only Python packer for their modern ICNS chunks, and
  `iconutil` only to decode-verify the finished container before `plutil` and
  `codesign`. This avoids the observed macOS 26.5 encoder regression that rejects
  even a valid iconset extracted from an existing ICNS; signing remains ad-hoc.
- Android gates require JDK 17, Android SDK platform 36, Build Tools 36.0.0,
  and the checked-in SHA-pinned Gradle 8.14.5 wrapper or `DROIDMATCH_GRADLE`.
- AndroidX Test runner 1.7.0 and ext.junit 1.3.0 compile the isolated Keystore
  instrumentation APK. `connectedDebugAndroidTest` remains an explicit device
  action and is not part of hosted CI.

- Protobuf schema 检查需要 `protoc`。
- 文档链接检查需要 Python 3，只校验本地 Markdown 链接目标；外部 URL 不放入 CI，
  避免网络波动导致 gate 不稳定。
- Mac 测试与产品构建共用 `tools/swift-build-compat.sh`：它创建稳定的 package-local
  module cache；只在 `CODEX_SANDBOX` 已提供外层边界时关闭 SwiftPM 冗余的嵌套 sandbox；
  且仅在默认 target 失败、显式回退 probe 成功后选择 arm64e。Mac 测试使用 Swift Testing
  宏，`tools/run-swift-tests.sh` 会先尝试当前 toolchain 的默认路径，
  然后回退到 Xcode 或 Command Line Tools 里的显式 `Testing.framework`、宏插件和运行时 rpath；
  runner 默认使用稳定、package-local 且已忽略的
  `${DROIDMATCH_SWIFT_SCRATCH_PATH:-mac/.build}/droidmatch-module-cache`
  （或遵循 `DROIDMATCH_SWIFT_MODULE_CACHE_PATH`），不依赖可能不可写的 home cache，
  也不使用会让增量链接保留缺失 PCM 引用的临时 cache。Swift Testing 动态宏使用
  `-load-plugin-library` 按 library 加载，不冒充 plugin executable。
  只有真实 probe 使用同一 framework、宏插件、SDK 与 target override 完成 typecheck 后才会接受
  该回退；仅发现文件不算成功，SDK/compiler 不匹配会在 `--probe-only` 阶段明确失败。
  只在存在 `CODEX_SANDBOX` 时，SwiftPM 才额外接收 `--disable-sandbox`
  以避免嵌套 `sandbox-exec` 失败；外层 Codex sandbox 仍是隔离边界，普通本地/CI 路径不变。
  每次选定/全量运行只构建一次完整测试包，随后测试清单和所有分片均使用 `--skip-build`，
  避免发现与执行之间静默重新链接不同字节；这些已准备执行统一受 60 秒进程组边界保护，
  macOS 开发者工具/dyld 策略若卡住，会终止全部后代进程并以 124 和明确诊断退出，而非
  无限等待。完整运行会显式清除 `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`，改用精确
  进程分片；测试清单必须非空且唯一，每个分片的 Swift Testing 顶层计数必须与所选
  specifier 数一致。
  若 CLT 更新导致默认 arm64 标准库不可加载、但 arm64e 探针成功，脚本才会额外选择 arm64e test triple，正常 CI 路径不变。
  macOS CI job 使用当前 GA 的 arm64 `macos-26` runner，内置 Xcode 26 镜像，避免依赖较旧的
  `macos-15` 默认 Xcode 配置。
- 本地 App 组装使用 macOS `sips` 生成十个精确 PNG rendition，由只依赖 Python
  标准库的严格 packer 写入现代 ICNS chunk，再仅用 `iconutil` 反向解码验收后执行
  `plutil`/`codesign`。这避开了 macOS 26.5 连既有 ICNS 自身解出的合法 iconset 都会拒绝的
  encoder 回归；签名仍只是 ad-hoc。
- Android gate 需要 JDK 17、Android SDK platform 36、Build Tools 36.0.0，以及仓库内
  带 SHA-256 固定的 Gradle 8.14.5 `android/gradlew` 或 `DROIDMATCH_GRADLE`。
- AndroidX Test runner 1.7.0 与 ext.junit 1.3.0 用于编译隔离的 Keystore
  instrumentation APK；`connectedDebugAndroidTest` 仍是显式真机动作，不进入托管 CI。

## Device Matrix

M1 real-device runs are not CI jobs. Record them with
`tools/run-m1-device-smoke.sh`, then commit the redacted logs under
`fixtures/m1-runs/` when they prove a new matrix case. Every new ordinary log
must carry one `m1-device-smoke-v1` profile; its result/check partitions,
provenance, slot/API, metrics, summary, and cleanup intent are validated as one
semantic record. Failed diagnostics cannot satisfy a criterion. The 89 older
unprofiled files are accepted only at the paths and byte digests frozen by
`legacy-v0.sha256`, so CI rejects both legacy drift and newly added unprofiled
logs. Only clean rebuilt full-revision ordinary runs are `device-evidence`;
dirty/unknown/reused passes are diagnostic-only. The current-tip Slot A throughput gate instead uses
`tools/run-m1-throughput-gate.sh`, whose `m1-adb-throughput-v2` log embeds a
validated generic producer record, binds the two records' full SHA/check plan/
overlapping metrics and fixed managed payload, and is published only after strict provenance,
preflight, 0.5-second child-run, post-run, and pre-publication enforcement of a
hub-free direct macOS USB topology, exact transfer, negotiated-chunk,
managed/download/upload SHA-256 equality, privacy,
cleanup, staged-profile, and no-clobber publication validation. The validator
keeps v2 pass-only and rejects throughput v1. After strict preflight, a failed
wrapper may publish the separate `m1-adb-throughput-diagnostic-v1` only if its
private `m1-device-smoke-v1` producer first passes standalone validation; that
combined failed diagnostic records bounded failure/provenance/digest/cleanup state,
preserves the non-zero exit, and never satisfies a criterion. Missing or invalid
producers, privacy or validator failures, and no-clobber races publish no
diagnostic. The wrapper removes its pre-created topology-failure guard only after
the supervisor reaps the complete child process group, exits successfully,
preserves the original guard identity, and its exact one-line child-status record validates;
monitor refusal/crash/signal or guard/status-I/O failure keeps topology failures
outside diagnostic publication. Evidence privacy
rejection never echoes the matching line.
Attended product insertion uses a separate `m1-product-usb-insertion-v1` fixture
directory and validator. CI exercises its AX policy, countdown state machine,
artifact metadata, privacy/schema rejection, regular-file/non-symlink boundary,
whole-directory allowed-entry preflight, exact-path no-clobber publication,
source/target replacement races, validated inode/SHA-256 binding, final-result
revalidation, persistent result/`.commit` pairing, orphan/mismatch rejection,
creation-window source replacement, uncertain-publication failure, Bash 3.2
zero-log behavior, and fixture count. Hidden,
unexpected, nested, non-regular, or unpaired directory entries fail closed. CI
cannot replace the physical cable action or the operator's post-run attestation.

M1 真机运行不是 CI job。使用 `tools/run-m1-device-smoke.sh` 记录结果；当日志证明新的设备矩阵场景时，把脱敏日志提交到
`fixtures/m1-runs/`。每份新普通日志必须包含唯一的 `m1-device-smoke-v1` profile，
其结果/检查分区、provenance、slot/API、指标、摘要与清理意图会作为一个语义记录校验；
只有 clean、rebuilt、完整 revision 的普通运行属于 `device-evidence`；
dirty/unknown/reused 的通过运行与失败运行都只算诊断，不能满足门槛。89 份旧无 profile 文件仅按 `legacy-v0.sha256` 冻结的路径与字节
摘要接受，因此 CI 会同时拒绝历史漂移和新增无 profile 日志。current-tip Slot A 吞吐
gate 则使用 `tools/run-m1-throughput-gate.sh`；其 `m1-adb-throughput-v2` 日志会内嵌已验证
的通用 producer 记录，绑定两份记录的完整 SHA/固定检查计划/重叠指标与固定受管 payload，
并且只有 provenance、所选 ADB 设备唯一对应不经过 Hub 的 macOS 主控直连路径，且该路径
在预检、底层 runner 全程每 0.5 秒、runner 结束和发布前都复验、
精确传输、实际协商 chunk、
受管源/下载/上传三方 SHA-256 一致性、隐私、清理、staged profile 与 no-clobber
发布严格验证完成后才会发布。validator 保持 v2 只能通过并继续拒绝吞吐 v1。
严格 preflight 之后 wrapper 若失败，只有私有 `m1-device-smoke-v1` producer 已先独立通过
validator，才可发布独立的 `m1-adb-throughput-diagnostic-v1`；该组合失败诊断只记录受限的
失败/provenance/摘要/清理状态，保留非零退出且永远不满足门槛。producer 缺失或无效、
隐私或 validator 失败、no-clobber 竞争都不发布诊断；隐私拒绝不会回显命中的原文行。
人工产品插入使用独立的 `m1-product-usb-insertion-v1` fixture 目录与校验器。CI 会覆盖
AX policy、倒计时状态机、artifact metadata、隐私/结构拒绝、普通文件/非 symlink 边界、
全目录允许项 preflight、精确路径 no-clobber 发布、源/目标替换竞态、已验证 inode/SHA-256
绑定、最终结果复验、持久 result/`.commit` 成对、孤立/不一致项拒绝、创建窗口源替换、
不确定发布失败、Bash 3.2 零日志行为和 fixture 计数。隐藏、意外、
嵌套、非普通或未成对目录项都会
fail closed，但 CI 不能替代真实插线动作与操作者事后确认。

## CD Status

Continuous delivery is intentionally not active yet. Release automation should
wait until M1 passes the required ADB device matrix and the product has a signed
macOS app target. CI now compiles the SwiftUI product and assembles/strictly
verifies ad-hoc local `.app` and mounted `.dmg` artifacts; this is build
evidence, not release signing. The future release workflow should replace the
ad-hoc identity with Developer ID signing, submit/staple notarization, publish
the checksum, and validate release notes.

Local App assembly builds and verifies a same-filesystem private candidate. A
first publication uses `RENAME_EXCL`; replacement of an existing App uses
`RENAME_SWAP`, with identities checked before and after the transition and state
recorded in a stable private transaction. Before any stale-transaction recovery and again
immediately before publication, a process guard refuses to overwrite a running
target App; Darwin compares both the current vnode path from `proc_pidpath` and
the kernel-retained `KERN_PROCARGS2` launch path, so rename, swap, and unlink remain
detectable, and unavailable inspection fails closed. Native behavior plus interrupted-
recovery regressions and the M0 source contract bind the two guard positions; the
mac-skeleton gate explicitly runs the platform behavior test. The next invocation recovers a tested
`SIGKILL` between swap and state update; active, unsafe, inconsistent, or legacy
transaction layouts fail closed. Publication owner markers bind PID to the boot
session and process start time, so an unrelated process reusing that PID does not
pin stale App or DMG state. Local
DMG assembly never publishes its candidate before image verification, read-only
mount inspection, mounted-App validation, and checksum generation all succeed.
The portable checksum sidecar records only the DMG basename, not a build-host
path; an operator therefore verifies it from the directory containing both files.
Its PID plus boot/start owner identity, bound marker, and initial state are first
synchronized in a private process-instance-scoped initializer; only the complete
directory is published at the stable
transaction name with `RENAME_EXCL`. Dead strictly allowlisted initializer and
legacy empty/owner/marker-only fragments are recoverable, while active, forged,
or unknown layouts fail closed. Candidate and previous hard links then live in
that transaction. An absent canonical node publishes with `RENAME_EXCL`; an
existing node publishes with `RENAME_SWAP` and two-way validation. Rollback uses
EXCL/SWAP according to recorded prior state. Recovery validates previous,
candidate, and canonical nodes before and after each transition by device, inode,
size, and SHA-256; concurrent insertion or later replacement is preserved and
fails closed, with both race classes covered offline. A validation failure preserves the
previous DMG/checksum pair. Offline tests cover each initialization boundary,
active-initializer preservation, a real building hard kill, recovery after the
DMG replacement, recognition of a complete pair replacement, and cleanup of an
interrupted first publication. These tests cover process termination, not
power-loss durability.
Swift protobuf regeneration first bootstraps the exact lockfile-pinned plugin
from a clean, unchanged checkout, then writes and validates every expected
generated source in a sibling transaction before replacing the tracked tree.
A failed bootstrap, compiler, or pre-publication validation leaves the previous
tree intact. After an atomic swap/install, recovery accepts only the recorded
candidate/previous mapping; an unknown or rebound mapping is preserved and
fails closed. Offline gates cover both Darwin publication and the Linux state
machine, concurrent insertion/replacement, unsafe nodes, and untrappable kills
after swap and first install. These tests prove process-level recovery, not
power-loss durability.

当前还没有启用持续交付。发布自动化应等待 M1 通过要求的 ADB 设备矩阵，并且产品具备已签名的 macOS app
target。CI 现已编译 SwiftUI 产品并严格校验 ad-hoc 本地 `.app` 与挂载后的 `.dmg`；这只是构建证据，不是发布签名。
未来 release workflow 应把 ad-hoc 身份替换为 Developer ID 签名，提交并 stapled 公证，发布 checksum，并校验 release note。

本地 App 组装会先在同一文件系统的私有候选中完成构建和验证；首次发布走
`RENAME_EXCL`，替换已有 App 走带前后身份复核的 `RENAME_SWAP`，并由稳定私有事务记录；
任何 stale-transaction recovery 前和最终发布前会两次拒绝覆盖仍在运行的目标 App；Darwin
同时比较 `proc_pidpath` 的当前 vnode 路径和内核保留的 `KERN_PROCARGS2` 原启动路径，
因此 rename、swap、unlink 均保持可检测，检查能力不可用则 fail closed。原生行为、运行中
事务恢复回归与 M0 源码契约固定两处 guard；mac-skeleton 显式运行平台行为测试。
离线测试覆盖 swap 与状态更新之间遭遇 `SIGKILL` 后由下一次运行恢复，
活动、不安全、不一致或旧版事务布局会 fail closed。本地 DMG 组装只有在镜像校验、
只读挂载、挂载后 App 复核与 checksum 生成全部成功后才发布候选。App 与 DMG 的 owner
marker 会把 PID 绑定到 boot session 与进程启动时刻，因此无关进程复用 PID 不会钉死
stale 事务。DMG 会先在进程实例作用域的
checksum sidecar 只记录可移植的 DMG basename，不嵌入构建机路径；人工校验应从 DMG
与 sidecar 所在目录执行。
私有 initializer 中写齐并同步 owner、绑定 marker 与初始 state，再以 `RENAME_EXCL`
原子发布稳定事务目录；死亡且严格 allowlist 的 initializer 与旧版空/仅 owner/marker
无 state 残片可恢复，活动、伪造或未知布局 fail closed。candidate 与旧产物硬链接随后
留在该稳定私有事务中；canonical 缺失走 `RENAME_EXCL`，已有目标走
双向复核的 `RENAME_SWAP`，回滚按原状态走 EXCL/SWAP。恢复会以
dev/inode/size/SHA-256 复核 previous、candidate、canonical 在每次转换前后的身份；
离线测试覆盖并发插入/替换，两者都保留现场并 fail closed。
任一验证失败都会保留上一对 DMG/checksum。
离线测试覆盖每个初始化边界、活跃 initializer、真实 building hard-kill、DMG 替换后恢复、
识别完整的成对替换，以及首次发布中断清理；
这些只证明进程终止恢复，不代表电源故障耐久性。Swift protobuf 再生成会先从干净、
未变化的 checkout 构建 lockfile 精确固定的插件，再在 sibling 私有事务中生成并核对
全部预期源码；bootstrap、compiler 或发布前验证失败都不改动旧生成树。原子 swap/install
之后，恢复只接受已记录的 candidate/previous 映射，未知或重绑定映射会保留现场并 fail
closed。离线门禁同时覆盖 Darwin 发布、Linux 状态机、并发插入/替换、不安全节点，以及
swap/首次 install 后的不可捕获终止；这些同样不代表电源故障耐久性。
