# Structural Debt Baseline

Last updated: 2026-07-15

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

<!-- source-size-max production=mac/Sources/DroidMatchCore/AsyncTransferScheduler.swift:689 test=android/app/src/test/java/app/droidmatch/m1/AdbEndpointTest.java:601 -->
<!-- test-inventory swift=293 android-unit=177 -->

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Large source files | **Unified budget enforced** | Every handwritten production and test Swift/Java/Kotlin file is at most 800 lines, with no exception; the largest production file is the 689-line Mac transfer scheduler and the largest test file is now the 601-line Android ADB-endpoint suite. The former 647-line directory-browser model suite now separates its 17 tests into a 258-line pagination/navigation/lifecycle suite and a 243-line mutation/media/presentation suite, sharing one 157-line actor-probe/fixture boundary; only test-target access changed, while MainActor behavior, test bodies, call ordering, production visibility, and the 293-test inventory remain unchanged. The former 658-line upload-coordinator suite now separates its three 220-line behavior tests from a 445-line local TCP recovery-server/support boundary; only test-target access changed, while production visibility, test bodies, wire timing, and the 293-test inventory remain unchanged. The former 674-line transfer-queue presentation suite now separates its 14 tests into a 90-line pure presentation/notification policy suite, a 273-line MainActor model suite, and a 75-line scheduler-adapter suite, all sharing one 251-line probe/support boundary; only test-target access changed, while production visibility, test bodies, and the 293-test inventory remain unchanged. The former 702-line product-session coordinator suite now separates its ten 359-line behavior tests from a 347-line probe/support boundary; only test-target access changed, production visibility and the 293-test inventory are unchanged. The former 727-line mixed-transfer server now keeps its 386-line listener/control plus happy path separate from a 246-line cancellation/reuse extension and a 109-line resume-failure extension; all extend the same server and share its existing state/wire helpers without copying lifecycle state or changing the then-293-test inventory. The former framed transfer extension is split into 209-line Control, 181-line Download, and 356-line Upload protocol-role extensions over the same server type, without copying live state or changing method bodies. Transfer-queue persistence evidence is split into a 128-line store format/permission contract and a 494-line scheduler restoration/fail-closed suite, sharing a 126-line deterministic fixture boundary without changing the then-275-test Swift inventory. Android dispatcher download evidence is now split into a 437-line resume/window/error/concurrency suite and a 272-line cancel/pause lifecycle suite, while heartbeat coverage lives with the 467-line general dispatcher suite; the 177-test Android inventory is unchanged. The former 2,526-line Mac frame/RPC fixture, 1,288-line multiplexer test, 1,173-line Android provider test, and 1,977-line dispatcher test are split by behavior/fixture ownership. Mac harness download and upload commands now live in separate 414/342-line files while remaining Core consumers. Android nonce/reconnect authentication is 295 lines and visible first pairing is 470 lines after pure limits/capability/payload policy moved to `RpcAuthenticationPolicy` and the two live paths received explicit owners; the transfer handler is 620 lines after pure wire construction/validation moved to `RpcTransferFrames`; the MediaStore catalog is 588 lines after typed page/album/lookup/metadata cursor scanning moved to the 159-line stateless `MediaStoreCursorReader`, while resolver/URI/query/permission/cache/error/thumbnail/transfer/pending-row ownership remains in the catalog; the SAF catalog is 630 lines after MIME/flag/order/partial-name policy moved to `SafDocumentPolicy` and six-column cursor decoding moved to the 154-line stateless `SafDocumentCursorReader`, while resolver/URI/permission/error/I/O ownership remains in the catalog. Scheduler request/persistence, coordinator/executor wiring, job execution event ordering, terminal-result calibration, local-endpoint projection, consumer delivery state, rate-expiry task ownership, and session-end transition policy have explicit boundaries; the actor is 689 lines, its 73-line actor-confined persistence state owns store I/O, coarse health, and the reload latch without retaining live records or publishing partial recovery; its 49-line actor-confined rate-expiry state replaces/cancels timer tasks without owning job records or publishing snapshots, pure shutdown/suspension record decisions return explicit effects, terminal outcomes/completion waiters/snapshot observers live in a separate actor-confined value, and the reusable execution probe lives with shared fixture construction. Scheduler behavior evidence is split into a 471-line retry/progress/terminal suite and a 247-line pause suite, sharing a 212-line fixture boundary without changing the then-275-test inventory. Multiplexer inbound response/stream application is grouped in a 236-line same-actor extension, leaving its lifecycle/send/transfer-admission core at 555 lines without copying route state. Product-session public values, protocols, and client seams live in `ProductDeviceSessionContracts`; ordered release of an atomically detached generation and its invalidatable transfer retry-client gate live in `ProductDeviceSessionResources`, leaving the lifecycle actor at 671 lines while it retains exclusive live-state, authentication, generation, and detach ownership. Mixed-server lock state, framed-server readers/response values, pure transfer fixture helpers, and restored-execution readiness tests are isolated. The product file-browser parent is 582 lines after its 190-line stateless chrome and separate stateless toolbar received explicit visual/action boundaries; state, panels, and queue submission remain in the parent. Its MainActor browser model is 573 lines after stable presentation values moved to an 87-line declaration boundary and direct-child/mutation/media/error decisions moved to a 150-line pure policy; client, task, generation, pagination, cache, mutation, and published state remain model-owned. Four real local TCP/RPC browser tests cover mutation and thumbnail request encoding, capability gates, bounded embedded errors, malformed responses, pre-wire path validation, and post-error session reuse; that change raised the Swift inventory to 279. |
| RPC deadline lifecycle | **Hardened with real TCP evidence** | Four tests hold real local TCP requests open to prove that control, download/upload open, and upload-ACK expiry return typed timeout failures and terminate the ambiguous multiplexed session. Deadline conversion saturates before `Double` to `UInt64` conversion, so even the largest finite timeout cannot trap at the rounded 2^64 boundary. That change raised the Swift inventory to 283. |
| M1 smoke orchestration | **Covered at the real TCP boundary** | Two tests drive the exact CLI wrapper over loopback TCP. The success path proves the ordered Hello, heartbeat, device info, canonical root listing, and diagnostics result; the failure path injects a recoverable remote application error and observes client EOF, proving the wrapper closes the session that the lower RPC layer intentionally leaves reusable. That change raised the Swift inventory to 285. |
| Transfer retry-session invalidation | **Deterministically covered** | Three tests exercise the product transfer gate: a real paired TCP handshake verifies the live endpoint/credential path, invalidation before connection rejects without invoking the connector, and an actor-held connector proves invalidation racing a completed connection closes that socket before returning cancellation. The seam is internal-only, while production retains the fixed lease endpoint and 10-second timeout. That change raised the Swift inventory to 288. |
| ADB forward lease lifecycle | **Fail-safe ownership covered** | Five focused tests cover preparation error normalization, device disappearance, same-device preparation exclusion, cancellation after forward allocation, and mismatched release. Release now validates the public capability before consuming the actor-private serial/port record, so the exact lease can still clean up after a mismatched attempt. `AdbDeviceDiscovery` owns only discovery and the dynamic loopback forward; authenticated RPC session ownership remains in `ProductDeviceSessionCoordinator`. The current Swift inventory is 293. |
| Synchronous Mac networking | **Removed** | Every product and CLI operation uses the async session/router. The semaphore transport, synchronous RPC client, and implementation-specific tests are deleted; stable errors/results live in transport-independent files. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, the current-state contribution guide, optional PR handoff template, bilingual live docs, deterministic gates, 293 Swift tests, and 177 Android unit tests/lint reduce undocumented knowledge. CI rejects drift of takeover, physical-device, 800-line, PR-evidence, and bilingual-resource contracts. A focused live-document truth gate now owns required high-risk facts, requires the English/Chinese M1 status dates to match, requires both status pages to retain the protected direct-main tool fact, and provides tested narrow semantic rejection for known-false SAF resume/cleanup and archived-device-evidence paraphrases; implementation seams remain a separate maintainer-contract check, and neither is presented as general semantic understanding. At the owner's explicit direction, Phase A permits no-PR fast-forward integration only after the exact candidate SHA receives all three hosted skeleton checks; administrator enforcement, main-tip revalidation, linear history, resolved conversations for optional PRs, and force-push/deletion bans remain. [GitHub Governance Baseline](github-governance.md) records the exact controls and the real second-maintainer Phase B. Ownership and release authority remain concentrated, and direct integration removes even the procedural PR boundary, so deterministic gates reduce bypass risk but cannot provide independent review. |
| macOS product App target | **Implemented; release evidence incomplete** | SwiftPM exposes a SwiftUI `DroidMatch` product with localized discovery, authentication, trusted-device revoke, browsing/transfers, persistent media-layout and opt-in privacy-bounded transfer notifications, a device-isolated queue, owner-scoped App-owned bookmark leases, ordinary/sandbox bundle assembly, and a mount-verified local DMG with checksum. Ordinary and sandboxed Slot C product authentication, browsing, bidirectional transfer, revocation, and forced-relaunch upload recovery are archived. Developer ID signing and notarization remain explicitly deferred and unverified. |
| Android product entry | **Secure onboarding and trust/authorization management implemented** | Product launcher `DroidMatchActivity` presents a tested top-level next-step summary and owns the paired-required endpoint, pairing approval, notification permission, paired-Mac list/revoke, and SAF root list/add/revoke. Static hierarchy construction is isolated in `DroidMatchScreen`, which receives action callbacks but cannot perform security-sensitive operations itself. Revoking trust closes the active USB service before it can be reused. CI assembles an unsigned release APK, verifies the product launcher, and rejects the debug harness in its merged manifest. It is not yet a local file browser or complete device-management UI. |

中文结论：生产与测试代码现已统一执行 800 行门禁；最大生产文件是 689 行的 Mac transfer scheduler，最大测试文件现为 601 行的 Android ADB endpoint 测试套件。原 647 行 DirectoryBrowserModel 套件现把 17 项测试拆为 258 行分页/导航/生命周期和 243 行 mutation/media/展示两组行为证据，共享一个 157 行 actor probe/fixture 边界；只调整测试 target 内部可见性，MainActor 行为、测试正文、调用顺序、生产可见性与 293 项 Swift 测试总数均未改变。原 658 行 upload coordinator 套件现把 3 项行为测试保留在 220 行文件中，并把本地 TCP 恢复服务器与同步 probe 归入 445 行共享 support；只调整测试 target 内部可见性，测试正文、wire 时序、生产可见性与 293 项 Swift 测试总数均未改变。原 674 行传输队列 Presentation 套件现把 14 项测试拆为 90 行纯展示/通知策略、273 行 MainActor 模型和 75 行 scheduler adapter 三组行为证据，共享一个 251 行 probe/support 边界；只调整测试 target 内部可见性，测试正文、生产可见性与 293 项 Swift 测试总数均未改变。原 702 行产品会话 coordinator 套件现拆为 359 行的 10 项行为测试和 347 行 probe/support 边界；只调整测试 target 内部可见性，生产可见性与 293 项 Swift 测试总数均未改变。原 727 行 mixed-transfer server 现拆为 386 行 listener/控制面与正常路径、246 行取消/复用 extension 和 109 行恢复失败 extension；三者扩展同一 server，并继续共享既有 state/wire helper，不复制生命周期状态，也未改变当时 293 项 Swift 测试。原 framed transfer extension 已按协议角色拆为 209 行 Control、181 行 Download 与 356 行 Upload 三个同类型 extension，未复制存活状态或修改方法体。transfer-queue persistence 证据现拆为 128 行的 store 格式/权限契约与 494 行的 scheduler 恢复/fail-closed 套件，共享 126 行确定性 fixture 边界，该次拆分未改变当时 275 项 Swift 测试。Android dispatcher 下载证据现拆为 437 行的续传/窗口/错误/并发套件与 272 行的取消/暂停生命周期套件，heartbeat 覆盖归入 467 行的通用 dispatcher 套件，Android 177 项测试数量不变。Mac harness 的下载/上传命令已拆成 414/342 行两个文件且仍只消费 Core。Android nonce/重连认证 handler 为 295 行、可见首次配对 handler 为 470 行，两者共享同一个进程级限速器；transfer handler 为 620 行。MediaStore catalog 降至 588 行，159 行无状态 cursor reader 只负责 typed page/album/lookup/metadata 解码，resolver、URI/query、实时权限、cache、错误映射、缩略图、传输与 pending row 仍由 catalog 唯一持有；SAF catalog 为 630 行，154 行无状态 cursor reader 只负责统一六列 projection 与 typed 行解码，resolver、URI、live permission、错误映射和全部 I/O 仍由 catalog 唯一持有。scheduler 的请求/持久化、coordinator/executor 装配、job execution 事件排序、终态结果校准、本地 endpoint 投影、consumer delivery state、速率过期 Task 所有权和 session-end transition policy 均已有明确边界，actor 已降至 689 行；73 行的 actor-confined persistence state 只持有 store I/O、粗粒度健康状态和 reload 闩锁，不保留 live record，也不会发布部分恢复结果；49 行的 actor-confined rate-expiry state 只替换/取消 timer Task，不持有 job record，也不发布快照；纯 shutdown/suspension 状态决策只返回显式 effect，终态 outcome、完成 waiter 和快照 observer 归入另一 actor 隔离值，共享 execution probe 也已归入 fixture 支持文件。scheduler 行为测试现拆为 471 行 retry/progress/terminal suite 与 247 行 pause suite，共享 212 行 fixture 边界，该次拆分未改变当时 275 项 Swift 测试。multiplexer 的入站 response/stream 应用现归入 236 行的同 actor extension，生命周期、发送与传输 admission 核心降至 555 行且没有复制 route 状态。产品会话的公开值、协议与 client 测试接缝归入 `ProductDeviceSessionContracts`；原子分离后的单代资源释放顺序和不可复活的 transfer retry-client gate 归入 `ProductDeviceSessionResources`，生命周期 actor 降至 671 行并继续独占存活状态、认证、generation 与 detach。产品文件浏览器父视图降至 582 行，190 行无状态 chrome 与独立无状态工具栏只接收展示值/动作，搜索、选择、面板和队列提交仍由父视图唯一持有；对应 MainActor 浏览模型降至 573 行，87 行稳定展示值边界与 150 行纯策略分别承载安全文件名和 direct-child/mutation/media/error 决策，client、Task、generation、分页、缓存、mutation 与 Published 状态仍由模型唯一持有。四项真实本地 TCP/RPC 浏览器测试现覆盖 mutation/thumbnail 编码、能力门禁、有界 provider 错误、畸形响应、发包前路径校验以及错误后的会话复用，该次改进使当时 Swift 测试总数增至 279。恢复执行 readiness 测试已拆入独立文件。存量巨石已按行为和 fixture 所有权拆分。单人维护风险仍只有部分治理；Mac 已接通认证会话、文件浏览、结构化诊断、持久双向队列和按认证 owner 隔离的 bookmark 租约，普通与 sandbox Slot C 产品认证、浏览、双向传输、撤销及强退后上传恢复均已有归档证据；Developer ID 签名与公证按当前决策暂缓且未验证。Android 已升级为安全连接 onboarding/status 与 SAF 授权管理入口，但完整本地文件浏览体验仍未完成。

活文档当前事实检查现由独立、可单测的门禁拥有：它保留必需高风险事实，要求中英文
M1 状态页更新时间一致且都记录受保护直推工具，并用窄范围语义规则拒绝已知错误的
SAF 续传/清理与已归档真机证据改写；实现接缝仍由维护者契约单独守护。两者都不冒充
通用语义审查，单维护者判断风险因此只是降低而非消失。


RPC deadline 现由四项真实本地 TCP 测试覆盖 control、download/upload open 与 upload ACK 超时；超时会返回 typed failure 并关闭歧义会话。纳秒换算在 `Double` 转 `UInt64` 前饱和，因此最大的有限 timeout 也不会在舍入后的 2^64 边界触发 trap；该次改进使当时 Swift 测试总数增至 283。

M1 smoke 编排现由两项真实本地 TCP 测试覆盖：成功路径验证 Hello、heartbeat、device info、canonical root listing 和 diagnostics 的顺序与聚合结果；失败路径注入底层会保留 session 的可恢复远端错误，并观察到客户端 EOF，从而证明 wrapper 会释放其独占连接。该项改进使当时 Swift 测试总数增至 285。

transfer retry-client gate 现有三项确定性测试：真实 TCP/配对认证覆盖生产 endpoint 与 credential 路径，失效前拒绝且不调用 connector，actor-held connector 则证明建连完成与失效竞态时会先关闭该 socket 再返回取消。测试接缝仅在模块内部可见，生产仍使用 lease endpoint 和固定 10 秒超时。该项改进使当时 Swift 测试总数增至 288。

ADB forward lease 生命周期新增五项聚焦测试，覆盖 preparation 错误归一化、设备消失、同设备并发 preparation 互斥、forward 分配后的取消清理以及 mismatch release。release 现在先校验公开 capability，再消费 actor 私有的 serial/port 清理记录，因此错误释放不会阻断后续精确 lease 的清理。`AdbDeviceDiscovery` 只拥有发现与动态 loopback forward，认证 RPC 会话仍由 `ProductDeviceSessionCoordinator` 建立。当前 Swift 测试总数为 293。

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
   validation and provider selection; `ProviderUploadLeases` owns process-wide
   canonical upload-destination exclusion across sessions. The 674-line facade retains the bounded SAF
   identity cache, catalog contracts, shared lease registry, and public composition/delegation surface.
   Its legacy exception has been removed.
2. **Android RPC dispatcher (default-budget reached):**
   `RpcTransferHandler` owns open/chunk/ACK/cancel/pause routing;
   `RpcTransferFrames` owns pure protobuf/CRC/fingerprint/chunk-size policy;
   `RpcTransferRegistry` owns session-scoped handle identity and teardown;
   `RpcTransferStreams` owns ACK-bounded stream state; `RpcAuthenticationHandler`
   owns nonce/reconnect exchanges; `RpcPairingHandler` owns visible first-pairing
   start/confirm/finalize while sharing the same rate limiter; and `RpcSessionState`
   owns provisional secret clearing. `RpcControlHandler` owns already-admitted
   control payload parsing/provider execution without session or socket state. The 503-line
   dispatcher now owns only envelope/session-phase/capability routing and its
   legacy exception has been removed.
3. **Mac harness commands (split complete):** the 512-line `main.swift` owns
   command dispatch and control probes; the 159-line
   `HarnessDirectoryCommands.swift` owns listing probes and privacy-bounded
   aggregate pagination; the 414-line
   `HarnessTransferCommands.swift` owns download probes; the 342-line
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
   lives in a 118-line same-actor extension that owns no copied state;
   inbound response/stream parsing, waiter resolution, route mutation, and
   bounded-queue yield are grouped in a 236-line same-actor extension. The
   555-line core retains the only reader plus lifecycle, send admission,
   transfer admission, socket, and termination ownership. Neither extension
   copies actor state, and the legacy exception remains removed.
   `AsyncTransferSchedulerPolicy` similarly owns pure persisted-state,
   checkpoint, metadata, and resume-request decisions;
   `AsyncTransferSchedulerPersistence` owns manifest/runtime conversion, while
   `AsyncTransferSchedulerJobRunner` owns stateless executor dispatch and the
   retry/progress/terminal ordering bridge. Pure shutdown/suspension record and
   queue decisions live in `AsyncTransferSchedulerSessionEndPolicy`, which
   returns explicit effects without owning tasks or I/O. The actor-confined
   `AsyncTransferSchedulerConsumerState` owns terminal outcomes, completion
   waiters, and snapshot observers without starting tasks or mutating jobs. The
   689-line scheduler actor retains live record/queue, broadcast, and
   executor-unwind ownership. Its 73-line actor-confined persistence state owns
   store I/O, coarse health, and the reload latch without retaining records or
   publishing partial recovery. Its 49-line actor-confined rate-expiry state
   owns only timer replacement/cancellation and cannot mutate a job or publish
   a snapshot.
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
