# Structural Debt Baseline

Last updated: 2026-07-11

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

<!-- source-size-max production=mac/Sources/DroidMatchCore/AsyncTransferScheduler.swift:744 test=mac/Tests/DroidMatchCoreTests/LocalFrameTestServer+Transfer.swift:737 -->

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Large source files | **Unified budget enforced** | Every handwritten production and test Swift/Java/Kotlin file is at most 800 lines, with no exception; the largest production file is the 744-line Mac scheduler and the largest test file is the 737-line Mac transfer-server fixture. The former 2,526-line Mac frame/RPC fixture, 1,288-line multiplexer test, 1,173-line Android provider test, and 1,977-line dispatcher test are split by behavior/fixture ownership. Mac harness download and upload commands now live in separate 412/340-line files while remaining Core consumers. The Android authentication handler is 719 lines after pure limits/capability/payload policy moved to `RpcAuthenticationPolicy`; the transfer handler is 617 lines after pure wire construction/validation moved to `RpcTransferFrames`; the SAF catalog is 701 lines after MIME/flag/order/partial-name policy moved to `SafDocumentPolicy`. Scheduler request/persistence and terminal-result calibration are pure policy; its reusable execution probe lives with shared fixture construction, leaving the main scheduler behavior suite at 721 lines. Mixed-server lock state, framed-server readers/response values, and pure transfer fixture helpers are isolated; and the product file-browser toolbar is a stateless action/state boundary. |
| Synchronous Mac networking | **Removed** | Every product and CLI operation uses the async session/router. The semaphore transport, synchronous RPC client, and implementation-specific tests are deleted; stable errors/results live in transport-independent files. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, the current-state contribution guide, required PR handoff template, bilingual live docs, deterministic gates, 216 Swift tests, 129 Android unit tests/lint, and the model-verified review wrapper reduce undocumented knowledge. CI rejects drift of takeover, physical-device, 800-line, PR-evidence, and bilingual-resource contracts. Phase A protection now requires an up-to-date PR, all three hosted skeleton checks, resolved conversations, and linear squash history on `main`; [GitHub Governance Baseline](github-governance.md) records the exact controls and the real second-maintainer Phase B. Ownership and release authority remain concentrated, so protection reduces bypass risk but cannot provide independent review. |
| macOS product App target | **Implemented; release evidence incomplete** | SwiftPM exposes a SwiftUI `DroidMatch` product with localized discovery, authentication, trusted-device revoke, browsing/transfers, persistent media-layout and opt-in privacy-bounded transfer notifications, a device-isolated queue, App-owned bookmark leases, ordinary/sandbox bundle assembly, and a mount-verified local DMG with checksum. Ordinary and sandboxed Slot C product authentication, browsing, bidirectional transfer, revocation, and forced-relaunch upload recovery are archived. Developer ID signing and notarization remain explicitly deferred and unverified. |
| Android product entry | **Secure onboarding and trust/authorization management implemented** | Product launcher `DroidMatchActivity` presents a tested top-level next-step summary and owns the paired-required endpoint, pairing approval, notification permission, paired-Mac list/revoke, and SAF root list/add/revoke. Static hierarchy construction is isolated in `DroidMatchScreen`, which receives action callbacks but cannot perform security-sensitive operations itself. Revoking trust closes the active USB service before it can be reused. CI assembles an unsigned release APK, verifies the product launcher, and rejects the debug harness in its merged manifest. It is not yet a local file browser or complete device-management UI. |

中文结论：生产与测试代码现已统一执行 800 行门禁；最大生产文件是 744 行的 Mac scheduler，最大测试文件为 737 行的 Mac transfer-server fixture。Mac harness 的下载/上传命令已拆成 412/340 行两个文件且仍只消费 Core。Android authentication handler 为 719 行，transfer handler 为 617 行，SAF catalog 为 701 行。scheduler 的请求/持久化与终态结果校准均已成为纯策略，共享 execution probe 也已归入 fixture 支持文件，主行为套件为 721 行。存量巨石已按行为和 fixture 所有权拆分。单人维护风险仍只有部分治理；Mac 已接通认证会话、文件浏览、结构化诊断、持久双向队列和 bookmark 租约，普通与 sandbox Slot C 产品认证、浏览、双向传输、撤销及强退后上传恢复均已有归档证据；Developer ID 签名与公证按当前决策暂缓且未验证。Android 已升级为安全连接 onboarding/status 与 SAF 授权管理入口，但完整本地文件浏览体验仍未完成。

## Source-size Guardrail

`python3 tools/check-source-size.py` applies one 800-line ceiling to handwritten
production, unit-test, and instrumentation-test Swift/Java/Kotlin files. Generated
protobuf/build outputs are excluded.

No legacy ceilings remain. The gate applies the same default limit to every
handwritten source file in its production and test roots. Structural boundaries
and behavior tests remain necessary; line count alone does not prove good
architecture.

## Decomposition Order

1. **Android provider facade (default-budget reached):** upload writers,
   download readers, shared helpers, app-sandbox, MediaStore, and SAF catalogs
   are separate. `ProviderPathRouter` now owns logical path/target validation and
   opaque SAF token routing; `ProviderPagePolicy` owns pure pagination/token
   validation; `ProviderDirectoryListings` owns root and provider-specific list
   response assembly; `ProviderTransfers` owns stateless download/upload argument
   validation and provider selection. The 657-line facade retains the bounded SAF
   identity cache, catalog contracts, and public composition/delegation surface.
   Its legacy exception has been removed.
2. **Android RPC dispatcher (default-budget reached):**
   `RpcTransferHandler` owns open/chunk/ACK/cancel/pause routing;
   `RpcTransferFrames` owns pure protobuf/CRC/fingerprint/chunk-size policy;
   `RpcTransferRegistry` owns session-scoped handle identity and teardown;
   `RpcTransferStreams` owns ACK-bounded stream state; `RpcAuthenticationHandler`
   owns reconnect/first-pairing exchanges; and `RpcSessionState` owns provisional
   secret clearing. The 574-line dispatcher now owns only envelope/session-phase/
   capability routing and its legacy exception has been removed.
3. **Mac harness commands (split complete):** the 611-line `main.swift` owns
   command dispatch and control probes; the 412-line
   `HarnessTransferCommands.swift` owns download probes; the 340-line
   `HarnessUploadCommands.swift` owns upload probes; and the small
   `HarnessCLI.swift` / `HarnessHelp.swift` files own parsing, typed failures,
   and usage text. All remain consumers of Core and no source-size exception is
   required.
4. **Mac async router (default-budget reached):** `AsyncRpcRoutingState` owns
   route records, request-ID rotation, and pure transfer/window validation. It
   owns no actor, task, waiter resolution, or socket. `AsyncRpcDeadlines` owns
   wall-clock deadline tasks without routing mutation, and
   `AsyncRpcTransferFrames` owns pure transfer protobuf construction. The
   Download-frame parsing and limit/checksum/offset validation now return an
   immutable result from the same pure boundary. Upload producer/ACK sequencing
   lives in a 111-line same-actor extension that owns no copied state;
   actor-owned route mutation, bounded-queue yield, waiter, socket, and
   termination ownership remain in the 685-line multiplexer. Its legacy
   exception has been removed.
   `AsyncTransferSchedulerPolicy` similarly owns pure persisted-state,
   checkpoint, metadata, and resume-request decisions, while
   `AsyncTransferSchedulerPersistence` owns manifest/runtime conversion. The
   scheduler actor is now 774 lines and retains only runtime
   queue/task/waiter/timer plus persistence-write ownership.
5. **Legacy synchronous removal (complete):** product, control, pairing, and
   transfer evidence paths use the async session and single-reader router. The
   old semaphore transport and synchronous RPC implementation are deleted; no
   blocking network call is hidden in a detached task.

## Product-surface Gate

The macOS SwiftUI target enters through `DeviceDiscovering` and
`DeviceDiscoveryModel`: its private queue owns blocking ADB commands, and raw
serials are replaced by process-local UUIDs before Presentation. The same actor
now owns dynamic forward leases; `ProductDeviceSessionCoordinator` owns identity
selection, Keychain credentials, pairing/authentication, socket teardown, and
lease release. `DeviceSessionModel` publishes only bounded state and unlocks the
live directory browser after proof. Raw ADB, protobuf values, and credentials
remain outside the UI; network and filesystem ownership remain off MainActor.
Local DMG packaging and
lifecycle-owned transfer persistence are implemented. Ordinary and sandboxed
Slot C product authentication and transfer evidence is archived; Developer ID
signing, notarization, and release automation remain deferred product work.

Android now has a product onboarding/status summary, but transport access remains
separate from media/storage permission and pairing approval. A richer launcher is
not evidence that the Mac product or M1 device matrix is complete; local browsing
and broader device-management UI remain open product work.
