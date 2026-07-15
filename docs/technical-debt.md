# Structural Debt Baseline

Last updated: 2026-07-15

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

<!-- source-size-max production=mac/Sources/DroidMatchCore/AsyncTransferScheduler.swift:631 test=mac/Tests/DroidMatchPresentationTests/DeviceSessionModelTests.swift:621 -->
<!-- test-inventory swift=320 android-unit=204 -->

Current UI-liveness hardening: trusted-device metadata loading now leaves its
busy state after five seconds, keeps one underlying Keychain request, and can
still apply that request's late success. A deterministic suspended-source test
guards the deadline, duplicate suppression, and recovery behavior; it does not
weaken or bypass Security.framework interaction.

中文：可信设备元数据加载现会在 5 秒后退出忙状态，同时只保留一个底层 Keychain
请求，并允许该请求的迟到成功自动恢复界面；确定性悬挂数据源测试覆盖 deadline、
重复抑制与恢复，且不会削弱或绕过 Security.framework 交互。

Current ready-assembly hardening: `DeviceSessionModel` publishes no browser,
diagnostics, transfer queue, or session info until all post-auth dependencies
succeed. A current-generation dependency failure shares one awaitable teardown
with explicit disconnect, publishes failure only after Core cleanup, and blocks a
replacement connect until that cleanup finishes. Five focused tests cover
authenticated reconnect and post-pairing errors, internal cancellation,
replacement ordering, and disconnect deduplication, raising the current Swift
inventory to 320.

中文：`DeviceSessionModel` 现仅在认证后的全部依赖成功后才发布浏览、诊断、传输队列
与会话信息；当前 generation 的依赖失败会与显式断开复用同一可等待 teardown，先完成
Core 清理再发布失败，并阻塞替换连接直至清理结束。五项聚焦测试覆盖已认证重连与配对后
错误、内部取消、替换顺序和断开去重，使当前 Swift 测试总数增至 320。

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Large source files | **Unified budget enforced** | Every handwritten production and test Swift/Java/Kotlin file is at most 800 lines, with no exception; the largest production file is now the 631-line Mac async-transfer scheduler and the largest test file is now the 621-line Mac device-session model suite with its deterministic teardown probe. The former 662-line Android provider facade now retains composition, the SAF cache lifetime, and process-wide upload leases in 415 lines; its unchanged MediaStore, SAF, and App Sandbox port methods/defaults live in 100/104/96-line package-private interfaces, concrete catalogs no longer implement facade-nested contracts, and that extraction left the then-180-test Android inventory unchanged. The former 586-line Mac local-frame server fixture now keeps listener/echo/general request scenarios in a 367-line base and moves its unchanged Hello/paired-authentication methods into a 225-line same-type extension; listener state, function visibility, wire order, and the 311-test Swift inventory remain unchanged. The former 592-line Android provider-transfer suite now separates its 21 unchanged tests into 211-line App Sandbox mutation/listing, 289-line App Sandbox transfer, and 121-line MediaStore/generic transfer suites; production visibility and the 180-test Android inventory remain unchanged. The former 601-line ADB-endpoint suite now separates its nine unchanged tests into 208-line admission, 164-line lifecycle, and 20-line log-privacy suites over one 249-line socket/latch support boundary; production visibility and the 180-test Android inventory remain unchanged. The former 647-line directory-browser model suite now separates its then-17 tests into a 258-line pagination/navigation/lifecycle suite and a 243-line mutation/media/presentation suite, sharing one 157-line actor-probe/fixture boundary; only test-target access changed, while MainActor behavior, test bodies, call ordering, production visibility, and the 293-test inventory remain unchanged. The former 658-line upload-coordinator suite now separates its three 220-line behavior tests from a 445-line local TCP recovery-server/support boundary; only test-target access changed, while production visibility, test bodies, wire timing, and the 293-test inventory remain unchanged. The former 674-line transfer-queue presentation suite now separates its 14 tests into a 90-line pure presentation/notification policy suite, a 273-line MainActor model suite, and a 75-line scheduler-adapter suite, all sharing one 251-line probe/support boundary; only test-target access changed, while production visibility, test bodies, and the 293-test inventory remain unchanged. The former 702-line product-session coordinator suite now separates its ten 359-line behavior tests from a 347-line probe/support boundary; only test-target access changed, production visibility and the 293-test inventory are unchanged. The former 727-line mixed-transfer server now keeps its 386-line listener/control plus happy path separate from a 246-line cancellation/reuse extension and a 109-line resume-failure extension; all extend the same server and share its existing state/wire helpers without copying lifecycle state or changing the then-293-test inventory. The former framed transfer extension is split into 209-line Control, 181-line Download, and 356-line Upload protocol-role extensions over the same server type, without copying live state or changing method bodies. Transfer-queue persistence evidence is split into a 128-line store format/permission contract and a 494-line scheduler restoration/fail-closed suite, sharing a 126-line deterministic fixture boundary without changing the then-275-test Swift inventory. Android dispatcher download evidence is now split into a 437-line resume/window/error/concurrency suite and a 272-line cancel/pause lifecycle suite, while heartbeat coverage lives with the 467-line general dispatcher suite; the then-177-test Android inventory was unchanged. The former 2,526-line Mac frame/RPC fixture, 1,288-line multiplexer test, 1,173-line Android provider test, and 1,977-line dispatcher test are split by behavior/fixture ownership. Mac harness download and upload commands now live in separate 414/342-line files while remaining Core consumers. Android nonce/reconnect authentication is 295 lines and visible first pairing is 470 lines after pure limits/capability/payload policy moved to `RpcAuthenticationPolicy` and the two live paths received explicit owners; the former 620-line transfer handler now keeps active chunk/ACK/cancel/pause/terminal-error teardown actions in 447 lines, while the 334-line `RpcTransferOpenHandler` owns open parsing, capability/concurrency admission, provider opening, and initial handle installation over the same sole registry; the MediaStore catalog retains resolver/URI/query/permission/cache/error/thumbnail/transfer/pending-row ownership after typed page/album/lookup/metadata cursor scanning moved to the stateless `MediaStoreCursorReader`; the SAF catalog retains live root/parent admission, listing/download/mutation, metadata validation, and per-chunk exact-tree authorization; `AndroidSafUploadOpener` owns authorized final/partial creation, exact child lookup, ACK-loss truncation, writer handoff, and pre-handoff cleanup, while the 61-line pure `SafUploadOpenPolicy` directly covers fresh/restart/resume plus partial kind/size decisions. Five policy tests raised the then-current Android unit inventory to 185; ten envelope-integrity and terminal transfer-lifecycle tests raised it to 195; five live-authorization tests raised it to 200; four media-permission/root-capability tests now raise it to 204. Scheduler request/persistence, coordinator/executor wiring, job execution event ordering, terminal-result calibration, local-endpoint projection, consumer delivery state, rate-expiry task ownership, session-end transition policy, and pause/resume/cancel transition policy have explicit boundaries; the actor is 631 lines, its 152-line pure control policy mutates only records/FIFO and returns ordered post-persistence effects, with four direct tests; its 73-line actor-confined persistence state owns store I/O, coarse health, and the reload latch without retaining live records or publishing partial recovery; its 49-line actor-confined rate-expiry state replaces/cancels timer tasks without owning job records or publishing snapshots, pure shutdown/suspension record decisions return explicit effects, terminal outcomes/completion waiters/snapshot observers live in a separate actor-confined value, and the reusable execution probe lives with shared fixture construction. Scheduler behavior evidence is split into a 471-line retry/progress/terminal suite and a 247-line pause suite, sharing a 212-line fixture boundary without changing the then-275-test inventory. Multiplexer inbound response/stream application is grouped in a 236-line same-actor extension, leaving its lifecycle/send/transfer-admission core at 555 lines without copying route state. Product-session public values, protocols, and client seams live in `ProductDeviceSessionContracts`; the immutable 136-line `ProductTransferSchedulerAssembly` reloads the exact fingerprint-bound credential before deriving the local-access owner, persistence store, invalidatable gate, and access-leased executors without owning generation or live scheduler state; the 140-line `ProductTransferPersistenceLocation` owns the domain-separated private queue route plus atomic no-clobber migration and fail-closed collision/symlink handling; the 118-line actor-confined `ProductTransferSchedulerLifecycle` atomically owns the retry gate, published scheduler, and generation-bound build while rejecting stale build-ID/object-identity cleanup; ordered release of an atomically detached generation and its invalidatable retry-client gate live in `ProductDeviceSessionResources`. Five direct assembly tests plus four persistence-location tests raised the then-current inventory to 310 Swift tests, and the 573-line coordinator actor remains the sole owner of authentication state, generation validation, scheduler publication/readiness, and asynchronous detach/cleanup. Mixed-server lock state, framed-server readers/response values, pure transfer fixture helpers, and restored-execution readiness tests are isolated. The product file-browser parent is 597 lines after its 190-line stateless chrome and separate stateless toolbar received explicit visual/action boundaries; state, panels, and queue submission remain in the parent. Its MainActor browser model is 572 lines after stable presentation values plus independent browse/upload projections moved to a 101-line declaration boundary and direct-child/mutation/media/error decisions moved to a 153-line pure policy; client, task, generation, pagination, cache, mutation, and published state remain model-owned. One unreadable-but-writable root test proves no navigation/list request while retaining upload capability and raised the then-current Swift inventory to 315. Four real local TCP/RPC browser tests cover mutation and thumbnail request encoding, capability gates, bounded embedded errors, malformed responses, pre-wire path validation, and post-error session reuse; that change raised the Swift inventory to 279. |
| RPC deadline lifecycle | **Hardened with real TCP evidence** | Four tests hold real local TCP requests open to prove that control, download/upload open, and upload-ACK expiry return typed timeout failures and terminate the ambiguous multiplexed session. Deadline conversion saturates before `Double` to `UInt64` conversion, so even the largest finite timeout cannot trap at the rounded 2^64 boundary. That change raised the Swift inventory to 283. |
| M1 smoke orchestration | **Covered at the real TCP boundary** | Two tests drive the exact CLI wrapper over loopback TCP. The success path proves the ordered Hello, heartbeat, device info, canonical root listing, and diagnostics result; the failure path injects a recoverable remote application error and observes client EOF, proving the wrapper closes the session that the lower RPC layer intentionally leaves reusable. That change raised the Swift inventory to 285. |
| Transfer retry-session invalidation | **Deterministically covered** | Three tests exercise the product transfer gate: a real paired TCP handshake verifies the live endpoint/credential path, invalidation before connection rejects without invoking the connector, and an actor-held connector proves invalidation racing a completed connection closes that socket before returning cancellation. The seam is internal-only, while production retains the fixed lease endpoint and 10-second timeout. That change raised the Swift inventory to 288. |
| ADB forward lease lifecycle | **Fail-safe ownership covered** | Five focused tests cover preparation error normalization, device disappearance, same-device preparation exclusion, cancellation after forward allocation, and mismatched release. Release now validates the public capability before consuming the actor-private serial/port record, so the exact lease can still clean up after a mismatched attempt. `AdbDeviceDiscovery` owns only discovery and the dynamic loopback forward; authenticated RPC session ownership remains in `ProductDeviceSessionCoordinator`. That change raised the Swift inventory to 293. |
| Synchronous Mac networking | **Removed** | Every product and CLI operation uses the async session/router. The semaphore transport, synchronous RPC client, and implementation-specific tests are deleted; stable errors/results live in transport-independent files. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, the current-state contribution guide, optional PR handoff template, bilingual live docs, deterministic gates, 320 Swift tests, and 204 Android unit tests/lint reduce undocumented knowledge. CI rejects drift of takeover, physical-device, 800-line, PR-evidence, and bilingual-resource contracts. A focused live-document truth gate now owns required high-risk facts, requires the English/Chinese M1 status dates to match, requires both status pages to retain the protected direct-main tool fact and the domain-separated queue-route fact, and provides tested narrow semantic rejection for known-false SAF resume/cleanup and archived-device-evidence paraphrases; implementation seams remain a separate maintainer-contract check, and neither is presented as general semantic understanding. At the owner's explicit direction, Phase A permits no-PR fast-forward integration only after the exact candidate SHA receives all three hosted skeleton checks; administrator enforcement, main-tip revalidation, linear history, resolved conversations for optional PRs, and force-push/deletion bans remain. [GitHub Governance Baseline](github-governance.md) records the exact controls and the real second-maintainer Phase B. Ownership and release authority remain concentrated, and direct integration removes even the procedural PR boundary, so deterministic gates reduce bypass risk but cannot provide independent review. |
| macOS product App target | **Implemented; release evidence incomplete** | SwiftPM exposes a SwiftUI `DroidMatch` product with localized discovery, authentication, trusted-device revoke, browsing/transfers, persistent media-layout and opt-in privacy-bounded transfer notifications, a device-isolated queue, owner-scoped App-owned bookmark leases, ordinary/sandbox bundle assembly, and a mount-verified local DMG with checksum. Ordinary and sandboxed Slot C product authentication, browsing, bidirectional transfer, revocation, and forced-relaunch upload recovery are archived. Developer ID signing and notarization remain explicitly deferred and unverified. |
| Android product entry | **Secure onboarding and trust/authorization management implemented** | Product launcher `DroidMatchActivity` presents a tested top-level next-step summary and owns the paired-required endpoint, pairing approval, notification permission, paired-Mac list/revoke, user-triggered photo/video permission or reselection, and SAF root list/add/revoke. Pure media policy keeps API request sets, callback fallback, and legacy write support separate from platform actions; live root read capability is independent from write capability. Static hierarchy construction is isolated in `DroidMatchScreen`, which receives action callbacks but cannot perform security-sensitive operations itself. Revoking trust closes the active USB service before it can be reused. CI assembles an unsigned release APK, verifies the product launcher, and rejects the debug harness in its merged manifest. The media UI has local automated evidence but no archived physical pass; Android is not yet a local file browser or complete device-management UI. |

中文结论：生产与测试代码现已统一执行 800 行门禁；最大生产文件现为 631 行的 Mac async-transfer scheduler，最大测试文件现为 621 行、包含确定性 teardown probe 的 Mac device-session model 套件。原 662 行 Android provider facade 现以 415 行保留组装、SAF cache 生命周期与进程级上传租约；未改方法/default 的 MediaStore、SAF、App Sandbox 端口分别归入 100/104/96 行 package-private 接口，具体 catalog 不再实现 facade 内嵌契约，当时 Android 180 项单元测试总数不变。原 586 行 Mac local-frame server fixture 现把 listener/echo/通用请求场景保留在 367 行基类，并把未改正文的 Hello/配对认证方法移入 225 行同类型 extension；listener 状态、函数可见性、wire 顺序与 311 项 Swift 测试总数不变。原 592 行 Android provider-transfer 套件现把 21 项未改正文的测试拆为 211 行 App Sandbox mutation/listing、289 行 App Sandbox transfer 与 121 行 MediaStore/通用 transfer 套件；生产可见性和 180 项 Android 单元测试总数不变。原 601 行 ADB endpoint 套件现把九项未改正文的测试拆为 208 行 admission、164 行 lifecycle 和 20 行日志隐私套件，共享一个 249 行 socket/latch support 边界；生产可见性和 180 项 Android 单元测试总数不变。原 647 行 DirectoryBrowserModel 套件曾把当时 17 项测试拆为 258 行分页/导航/生命周期和 243 行 mutation/media/展示两组行为证据，共享一个 157 行 actor probe/fixture 边界；只调整测试 target 内部可见性，MainActor 行为、测试正文、调用顺序、生产可见性与 293 项 Swift 测试总数均未改变。原 658 行 upload coordinator 套件现把 3 项行为测试保留在 220 行文件中，并把本地 TCP 恢复服务器与同步 probe 归入 445 行共享 support；只调整测试 target 内部可见性，测试正文、wire 时序、生产可见性与 293 项 Swift 测试总数均未改变。原 674 行传输队列 Presentation 套件现把 14 项测试拆为 90 行纯展示/通知策略、273 行 MainActor 模型和 75 行 scheduler adapter 三组行为证据，共享一个 251 行 probe/support 边界；只调整测试 target 内部可见性，测试正文、生产可见性与 293 项 Swift 测试总数均未改变。原 702 行产品会话 coordinator 套件现拆为 359 行的 10 项行为测试和 347 行 probe/support 边界；只调整测试 target 内部可见性，生产可见性与 293 项 Swift 测试总数均未改变。原 727 行 mixed-transfer server 现拆为 386 行 listener/控制面与正常路径、246 行取消/复用 extension 和 109 行恢复失败 extension；三者扩展同一 server，并继续共享既有 state/wire helper，不复制生命周期状态，也未改变当时 293 项 Swift 测试。原 framed transfer extension 已按协议角色拆为 209 行 Control、181 行 Download 与 356 行 Upload 三个同类型 extension，未复制存活状态或修改方法体。transfer-queue persistence 证据现拆为 128 行的 store 格式/权限契约与 494 行的 scheduler 恢复/fail-closed 套件，共享 126 行确定性 fixture 边界，该次拆分未改变当时 275 项 Swift 测试。Android dispatcher 下载证据现拆为 437 行的续传/窗口/错误/并发套件与 272 行的取消/暂停生命周期套件，heartbeat 覆盖归入 467 行的通用 dispatcher 套件，Android 177 项测试数量不变。Mac harness 的下载/上传命令已拆成 414/342 行两个文件且仍只消费 Core。Android nonce/重连认证 handler 为 295 行、可见首次配对 handler 为 470 行，两者共享同一个进程级限速器；原 620 行 transfer handler 现以 447 行保留活动 chunk/ACK/cancel/pause/终止错误 teardown 动作，334 行 `RpcTransferOpenHandler` 则在同一个唯一 registry 上独占 open 解析、能力/并发准入、provider 打开与初始 handle 安装。MediaStore catalog 在无状态 cursor reader 承担 typed page/album/lookup/metadata 解码后，仍唯一持有 resolver、URI/query、实时权限、cache、错误映射、缩略图、传输与 pending row；SAF catalog 继续负责实时 root/parent admission、列表/下载/mutation、metadata 验证与逐 chunk 精确 tree 授权；`AndroidSafUploadOpener` 独占已授权 final/partial 创建、精确 child 查找、ACK-loss 截断、writer 交接和交接前清理，61 行纯 `SafUploadOpenPolicy` 直接覆盖 fresh/restart/resume 及 partial kind/size 决策，新增五项 policy 测试曾使当时 Android 单元测试增至 185；十项 envelope 完整性与终止性 transfer 生命周期测试使其增至 195；五项活动授权测试使总数增至 200；四项媒体权限策略/root capability 测试使当前 Android 单元测试总数增至 204。scheduler 的请求/持久化、coordinator/executor 装配、job execution 事件排序、终态结果校准、本地 endpoint 投影、consumer delivery state、速率过期 Task 所有权、session-end transition policy 与 pause/resume/cancel transition policy 均已有明确边界，actor 已降至 631 行；152 行纯控制策略只修改 record/FIFO 并返回写盘后的有序副作用，四项直接测试覆盖控制策略；73 行 actor-confined persistence state 只持有 store I/O、粗粒度健康状态和 reload 闩锁，不保留 live record，也不会发布部分恢复结果；49 行 actor-confined rate-expiry state 只替换/取消 timer Task，不持有 job record，也不发布快照；纯 shutdown/suspension 状态决策只返回显式 effect，终态 outcome、完成 waiter 和快照 observer 归入另一 actor 隔离值，共享 execution probe 也已归入 fixture 支持文件。scheduler 行为测试现拆为 471 行 retry/progress/terminal suite 与 247 行 pause suite，共享 212 行 fixture 边界，该次拆分未改变当时 275 项 Swift 测试。multiplexer 的入站 response/stream 应用现归入 236 行的同 actor extension，生命周期、发送与传输 admission 核心降至 555 行且没有复制 route 状态。产品会话的公开值、协议与 client 测试接缝归入 `ProductDeviceSessionContracts`；136 行不可变 `ProductTransferSchedulerAssembly` 在派生匿名本地授权 owner、持久化 store、不可复活 gate 与带 lease 的执行器前重新校验精确指纹凭据，且不持有 generation 或 live scheduler；140 行 `ProductTransferPersistenceLocation` 独占域分离的私有队列路由、原子无覆盖迁移及冲突/符号链接 fail-closed 处理；118 行 actor-confined `ProductTransferSchedulerLifecycle` 原子持有 retry gate、已发布 scheduler 与 generation-bound build，并以 build ID/对象身份拒绝旧构建清理新资源；原子分离后的单代资源释放顺序和不可复活的 retry-client gate 归入 `ProductDeviceSessionResources`。五项直接 assembly 测试与四项持久位置测试使当时 Swift 测试总数升至 310，573 行 coordinator actor 继续独占认证状态、generation 校验、scheduler 发布/readiness 和异步 detach/cleanup。产品文件浏览器父视图现为 597 行，190 行无状态 chrome 与独立无状态工具栏只接收展示值/动作，搜索、选择、面板和队列提交仍由父视图唯一持有；对应 MainActor 浏览模型现为 572 行，101 行稳定展示值/独立浏览上传投影边界与 153 行纯策略分别承载安全文件名和 direct-child/mutation/media/error 决策，client、Task、generation、分页、缓存、mutation 与 Published 状态仍由模型唯一持有。新增一项不可读但可写 root 测试证明不会导航或发送第二次 listing，同时保留上传能力，并使当时 Swift 测试总数增至 315。四项真实本地 TCP/RPC 浏览器测试现覆盖 mutation/thumbnail 编码、能力门禁、有界 provider 错误、畸形响应、发包前路径校验以及错误后的会话复用，该次改进使当时 Swift 测试总数增至 279。恢复执行 readiness 测试已拆入独立文件。存量巨石已按行为和 fixture 所有权拆分。单人维护风险仍只有部分治理；Mac 已接通认证会话、文件浏览、结构化诊断、持久双向队列和按认证 owner 隔离的 bookmark 租约，普通与 sandbox Slot C 产品认证、浏览、双向传输、撤销及强退后上传恢复均已有归档证据；Developer ID 签名与公证按当前决策暂缓且未验证。Android 已升级为安全连接 onboarding/status、用户主动触发的媒体权限与 SAF 授权管理入口；媒体 root 的实时读取能力与写入能力独立，产品媒体 UI 尚无真机归档，完整本地文件浏览体验仍未完成。

此次收敛把 SAF capability 缓存从 facade 内的通用 `Map` 提取为 41 行
`ProviderSafDocumentCache`：facade 仍独占其生命周期，cache 单独负责按 root 隔离的
opaque token、同步 access-order LRU 和逐出；两项直接 JVM 测试覆盖访问刷新、逐出和
跨 root 拒绝，wire path、错误码、4096 项生产上限与 provider I/O 均未改变。

活文档当前事实检查现由独立、可单测的门禁拥有：它保留必需高风险事实，要求中英文
M1 状态页更新时间一致且都记录受保护直推工具与域分离队列路由，并用窄范围语义规则拒绝已知错误的
SAF 续传/清理与已归档真机证据改写；实现接缝仍由维护者契约单独守护。两者都不冒充
通用语义审查，单维护者判断风险因此只是降低而非消失。


RPC deadline 现由四项真实本地 TCP 测试覆盖 control、download/upload open 与 upload ACK 超时；超时会返回 typed failure 并关闭歧义会话。纳秒换算在 `Double` 转 `UInt64` 前饱和，因此最大的有限 timeout 也不会在舍入后的 2^64 边界触发 trap；该次改进使当时 Swift 测试总数增至 283。

M1 smoke 编排现由两项真实本地 TCP 测试覆盖：成功路径验证 Hello、heartbeat、device info、canonical root listing 和 diagnostics 的顺序与聚合结果；失败路径注入底层会保留 session 的可恢复远端错误，并观察到客户端 EOF，从而证明 wrapper 会释放其独占连接。该项改进使当时 Swift 测试总数增至 285。

transfer retry-client gate 现有三项确定性测试：真实 TCP/配对认证覆盖生产 endpoint 与 credential 路径，失效前拒绝且不调用 connector，actor-held connector 则证明建连完成与失效竞态时会先关闭该 socket 再返回取消。测试接缝仅在模块内部可见，生产仍使用 lease endpoint 和固定 10 秒超时。该项改进使当时 Swift 测试总数增至 288。

ADB forward lease 生命周期新增五项聚焦测试，覆盖 preparation 错误归一化、设备消失、同设备并发 preparation 互斥、forward 分配后的取消清理以及 mismatch release。release 现在先校验公开 capability，再消费 actor 私有的 serial/port 清理记录，因此错误释放不会阻断后续精确 lease 的清理。`AdbDeviceDiscovery` 只拥有发现与动态 loopback forward，认证 RPC 会话仍由 `ProductDeviceSessionCoordinator` 建立。该次改进使当时的 Swift 测试总数升至 293。

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
   canonical upload-destination exclusion across sessions. The 415-line facade retains
   the shared lease registry, typed cache lifetime, and public composition/delegation
   surface. The 100/104/96-line `ProviderMediaCatalog`, `ProviderSafCatalog`, and
   `ProviderAppSandboxCatalog` boundaries own the package-private storage contracts and
   fail-closed empty defaults; concrete Android catalogs no longer implement facade-nested
   interfaces. The 41-line `ProviderSafDocumentCache` alone owns
   root-scoped opaque token generation/resolution and the synchronized access-order LRU map;
   two direct tests cover access refresh, eviction, and cross-root rejection. Its legacy
   exception has been removed.
2. **Android RPC dispatcher (default-budget reached):**
   `RpcTransferOpenHandler` owns open admission/provider handle installation over
   the sole registry supplied by `RpcTransferHandler`, which owns active
   chunk/ACK/cancel/pause routing and session teardown;
   `RpcTransferFrames` owns pure protobuf/CRC/fingerprint/chunk-size policy;
   `RpcTransferRegistry` owns session-scoped handle identity and teardown;
   `RpcTransferStreams` owns ACK-bounded stream state; `RpcAuthenticationHandler`
   owns nonce/reconnect exchanges; `RpcPairingHandler` owns visible first-pairing
   start/confirm/finalize while sharing the same rate limiter; and `RpcSessionState`
   owns provisional secret clearing. `RpcControlHandler` owns already-admitted
   control payload parsing/provider execution without session or socket state. The 546-line
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
   queue decisions live in `AsyncTransferSchedulerSessionEndPolicy`, while
   reversible pause/resume/cancel record and FIFO mutations live in the pure
   `AsyncTransferSchedulerControlPolicy`; its ordered effects cross persistence
   before the actor applies them. Both policies own no tasks or I/O. The actor-confined
   `AsyncTransferSchedulerConsumerState` owns terminal outcomes, completion
   waiters, and snapshot observers without starting tasks or mutating jobs. The
   631-line scheduler actor retains live record/queue, runtime effects, broadcast, and
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

Android now has a product onboarding/status summary plus explicit media and SAF
authorization management, but transport access remains separate from both
permission surfaces and pairing approval. Mac treats root read/write capability
independently, refusing unreadable navigation while retaining a valid direct
upload. These local changes are not physical-device evidence and a richer
launcher is not proof that M1 or the broader device-management UI is complete.
