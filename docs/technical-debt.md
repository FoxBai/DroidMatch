# Structural Debt Baseline

Last updated: 2026-07-19

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

<!-- source-size-max production=mac/Sources/DroidMatchCore/AsyncTransferScheduler.swift:743 test=android/app/src/test/java/app/droidmatch/m1/DmFileProviderSafTest.java:737 -->
<!-- tool-size-max path=tools/test-run-m1-throughput-gate.sh:800 -->
<!-- test-inventory swift=473 android-unit=242 -->

The former 755-line `AtomicDownloadWriter.swift` now keeps descriptor and
transaction orchestration in 480 lines. A 274-line stateless
`AtomicDownloadPartialFile` owns no-follow directory opening, partial creation,
single-link regular-file validation, non-blocking `flock`, descriptor/name inode
reconciliation, and exact destination snapshot comparison without retaining any
descriptor or writer state. All 18 focused atomic-download tests pass unchanged;
the then-427-test Swift inventory was unchanged.

中文：原 755 行 `AtomicDownloadWriter.swift` 现以 480 行保留 descriptor 与事务编排；
274 行无状态 `AtomicDownloadPartialFile` 负责 no-follow 目录打开、partial 创建、单链接
普通文件校验、非阻塞 `flock`、descriptor/name inode 对账及精确目标快照比较，且不保留
任何 descriptor 或 writer 状态。18 项原子下载专项测试原样通过，当时 427 项 Swift
测试库存未改变。

The former 768-line `AsyncTransferScheduler.swift` now keeps live task, record,
queue, persistence-effect, timer, and publication ownership in 743 lines. A
120-line pure `AsyncTransferSchedulerExecutionPolicy` validates retry attempt
accounting, makes retry persistence rollback explicit, accepts only monotonic
stable-total progress, and expires only the current running rate generation. It
owns no task, timer, store, queue, continuation, socket, or broadcast. Four
direct tests cover those transitions, bringing the Swift inventory to 431; the
existing 68-line completion policy still owns executor-unwind reconciliation.

中文：原 768 行 `AsyncTransferScheduler.swift` 现以 743 行继续唯一持有存活 Task、
record、queue、持久化副作用、timer 与发布；120 行纯
`AsyncTransferSchedulerExecutionPolicy` 校验 retry attempt、明确 retry 写盘失败回滚、
只接受总量稳定的单调进度，并只让当前运行 rate generation 过期。它不持有 task、timer、
store、queue、continuation、socket 或 broadcast。四项直接测试使 Swift 库存增至 431；
既有 68 行 completion policy 仍负责 executor 退场对账。

The former 774-line `DirectoryBrowserModel.swift` now keeps published state,
listing generations, navigation, derivative Tasks/previews/permission decisions,
and path-gated mutation outcome application in 628 lines. A 132-line pure
`DirectoryBrowserThumbnailState` owns generation, FIFO, active keys, failure
deduplication, and the 64-entry/8-MiB cache. It retains draining old-generation
requests against the four-request limit while rejecting stale publication, and
owns no client, Task, permission decision, or Published value. Three direct tests
cover that concurrency invariant, visible/failure admission, and both cache bounds,
bringing the then-current Swift inventory to 437. A 157-line MainActor mutation runner
separately owns the active remote-mutation Task and operation identity.

中文：原 774 行 `DirectoryBrowserModel.swift` 现以 628 行继续持有 Published 状态、
listing generation、导航、派生 Task/预览/权限判断及按 path 应用 mutation 结果。132 行
纯 `DirectoryBrowserThumbnailState` 独占 generation、FIFO、active key、失败去重及
64 项/8 MiB 缓存；旧 generation 已准入请求在排空前仍计入四项上限，但不能发布，且该
纯值不持有 client、Task、权限判断或 Published 值。三项直接测试覆盖该并发不变量、
可见性/失败准入与两项缓存上限，使当时 Swift 库存增至 437。157 行 MainActor mutation
runner 另独占活跃远端 mutation Task 与操作身份。

The former 679-line `AndroidAppSandboxCatalog.java` now keeps provider listing,
mutation, transfer, and staging lifecycle ownership in 646 lines. A 65-line
stateless `AppSandboxPathResolver` is the single filesystem admission boundary
for all four paths: it applies the shared lexical policy, confines canonical
results below the app root, and rejects every existing symbolic-link component.
It owns no authorization, descriptor, provider handle, or operation state.
Three direct JVM tests cover ordinary/future entries, root/traversal/reserved-name
aliases, and direct/nested links, bringing the Android inventory to 237.

中文：原 679 行 `AndroidAppSandboxCatalog.java` 现以 646 行继续独占 provider listing、
mutation、transfer 与 staging 生命周期。65 行无状态 `AppSandboxPathResolver` 成为四类
操作共用的唯一文件系统准入边界：应用共享词法规则、将 canonical 结果限制在
app root 下，并拒绝每个已存在的符号链接 component。它不持有授权、descriptor、
provider handle 或操作状态。三项直接 JVM 测试覆盖普通/未来 entry、root/traversal/
保留名别名和直接/嵌套链接，使 Android 库存增至 237。

The lock-backed `AsyncRpcOneShot` shared by RPC responses, transfer opens,
upload acknowledgements, bounded download waits, and readiness gates now claims
its single consumer atomically before cancellation or continuation setup. A
second wait returns a typed internal state error instead of replacing an active
continuation, hanging the original task, or reaching the former post-consumption
precondition crash. A defensive missing-result branch also throws instead of
terminating the process. One direct regression brings the Swift inventory to 438.

中文：RPC response、transfer open、upload ACK、有界 download wait 与 readiness gate
共用的 lock-backed `AsyncRpcOneShot` 现在会在 cancellation 或 continuation 安装前
原子认领唯一消费者。第二次 wait 会返回 typed 内部状态错误，不再覆盖
活跃 continuation、永久挂起原 task，也不会进入原先的结果消费后
precondition crash。防御性 missing-result 分支也改为 throw 而不是终止进程。
一项直接回归使 Swift 库存增至 438。

`AsyncFramedTcpSession` now reuses that one-shot for Network.framework
completion, timeout, and cancellation instead of maintaining a second trapping
continuation gate, while retaining first-completion behavior. The RPC client's
negotiated handshake is now the associated value of its `ready` state, so a
ready-without-cache state cannot exist. Process-local persistence reload returns
the existing stable `ioFailure` instead of terminating the process. Scheduler
admission uses Swift typed throws, making the compatibility projection exhaustive
without a fallback process trap. One direct regression brought the then-current Swift
inventory to 439; wire behavior is unchanged.

中文：`AsyncFramedTcpSession` 现在让 Network.framework completion、timeout 与
cancellation 复用同一个 one-shot，不再维护第二套可能 trap 的 continuation gate，且
保留首个结果优先语义。RPC client 的协商 handshake 直接成为 `ready` state 的关联值，
类型上不再存在 ready 但缺失 cache 的组合。process-local persistence reload 返回既有
稳定 `ioFailure`，不再终止进程。scheduler admission 使用 Swift typed throws，让兼容
投影的错误类型可穷尽，不再需要兜底进程 trap。一项直接回归使当时 Swift 库存增至 439；
wire 行为不变。

Timeout input now has one shared fail-closed conversion boundary. Non-positive,
NaN, and infinite values are rejected before transport or subprocess side
effects; huge finite values saturate before integer and `DispatchTime`
conversion. The harness also rejects a missing `--timeout-seconds` value, and
product ADB discovery maps invalid configured durations to stable `timedOut`
before process launch. Six direct regressions brought the then-current Swift
inventory to 445. The real login-Keychain
round trip is opt-in through `DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST=1`, so ordinary
gates retain injected-backend coverage without requesting Keychain secrets.

中文：timeout 输入现统一经过一个 fail-closed 换算边界。非正数、NaN 与无穷大会在
transport 或子进程副作用前拒绝；超大有限值会在整数与 `DispatchTime` 转换前饱和。
harness 也会拒绝缺值的 `--timeout-seconds`；产品 ADB 发现会在启动进程前把非法配置时长
归一为稳定 `timedOut`。六项直接回归使当时 Swift 库存增至 445。
真实登录钥匙串 round-trip 仅在设置 `DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST=1` 时运行，
普通门禁继续由注入后端覆盖，不再请求钥匙串机密。

The schema-v1 diagnostics exporter now reuses the product normalization boundary
at export time. A separately constructed public snapshot cannot emit unbounded or
control-bearing device text, invalid SDK/storage/battery values, an error count
outside 0–100, or negative counters. One direct malicious-snapshot regression
brought the then-current Swift inventory to 446 without changing the schema or adding
device/release evidence.

中文：schema-v1 诊断导出器现在会在导出时复用产品归一化边界。即使公开快照由其他调用方
单独构造，也不能输出无界/带控制字符的设备文本、非法 SDK/存储/电量、0–100 之外的错误数
或负计数器。一项恶意构造快照直接回归使当时 Swift 库存增至 446；schema、真机和发布证据
均不改变。

Trusted-device display now has a dedicated Keychain operation that never reads
generic-password data. It validates the key-free envelope or legacy
account/label/Keychain dates. Explicit-connection credential selection remains
the only secret-reading boundary. The migration regression at this milestone
proved display reads zero password values and selector migration reads exactly
one; the then-current Swift inventory remained 447. Later current-tree hardening
below replaces the single-legacy assumption with a shared-context migration for
multiple old records.

中文：可信设备展示现使用专用 Keychain 操作，永不读取 generic-password 数据；它会校验
无密钥 envelope 或旧记录的 account、label 与 Keychain 时间。只有明确连接后的凭据选择
才允许读取机密。这个里程碑的迁移回归证明展示读取 0 次密码值、单条 selector 迁移读取
1 次；当时 Swift 库存仍为 447。下方当前树加固已把“仅一条旧记录”的假设替换为多条旧记录
共享认证上下文的迁移。

The former 783-line `ProductFileBrowserView.swift` now keeps SwiftUI state,
native panels, mutations, and queue submission in 682 lines. Its unchanged
list/grid rendering lives in a 140-line stateless state/actions component. A
93-line pure `DirectoryBrowserSelectionState` owns selection-mode/path
reconciliation, capability-gated select-all, current-row-order projection, and
accepted-only batch subtraction without a model, task, panel, or queue. Three
direct tests cover those invariants, bringing the then-current Swift inventory to
434. A 135-line AppSupport policy separately fail-closes native-panel completion
against the exact current query, row snapshot, authorization, and persistence
readiness; five direct policy tests raised the earlier inventory to 425.

中文：原 783 行 `ProductFileBrowserView.swift` 现以 682 行继续持有 SwiftUI 状态、
原生面板、mutation 与队列提交；未改行为的列表/网格渲染归入 140 行无状态
state/actions 组件。93 行纯 `DirectoryBrowserSelectionState` 独占选择模式/path 对账、
按 capability 全选、按当前行序投影及仅扣除已受理批量路径，且不持有 model、Task、
panel 或 queue；三项直接测试覆盖这些不变量，使当时 Swift 测试库存增至 434 项。
135 行 AppSupport 纯策略另在面板完成时复核精确 query、row 快照、授权与持久化
readiness；五项直接策略测试曾使较早库存增至 425 项。

The former 788-line `PrivateAtomicFileWriter.swift` now keeps the three
read/write/remove transaction orchestrators in 371 lines, while its unchanged
pinned-location, snapshot, rollback, recovery-name, unlink, and directory-sync
proof helpers live in a 425-line same-module extension. No syscall order, error
mapping, transaction state, or product API changed. Eight focused filesystem and
cross-process lock tests passed after the split; the then-420-test Swift
inventory was unchanged.

中文：原 788 行 `PrivateAtomicFileWriter.swift` 现以 371 行保留 read/write/remove
三项事务编排；未改行为的目录钉住、快照、回滚、恢复名、精确删除与目录同步 proof helper
归入 425 行的同模块 extension。系统调用顺序、错误映射、事务状态与产品 API 均未改变；
拆分后八项文件系统/跨进程锁专项测试通过；当时 420 项 Swift 测试库存未改变。

Current Android pairing accessibility no longer exposes the visual countdown as
a 500 ms-polled polite live region. A pure policy projects controller snapshots
into closed, waiting, approval-required, approved, and rejected states; a stable
stage-only polite live region changes only at those boundaries, while a separate
accessibility-hidden view keeps the seconds visual. This avoids Android 16's
deprecated explicit announcement API and suppresses unchanged client/code writes.
The six-digit SAS is absent
from the accessibility tree outside an active approval and is labeled as six
separate ASCII digits while pending. Two JVM tests reject inconsistent state and
malformed SAS projections; maintainer fail-closed coverage guards the stable
stage/countdown split and forbids explicit accessibility announcements. That
increment brought the Android inventory to 234. This is offline evidence only.

中文：Android 配对无障碍不再把每 500 毫秒轮询的视觉倒计时作为 polite live region。
纯策略把 controller 快照投影为关闭、等待、待批准、已批准和已拒绝；稳定的阶段
live region 仅在这些边界变化，秒数由独立且从无障碍树隐藏的控件正常显示。实现不使用
Android 16 已弃用的主动 announcement API，客户端与配对码未变化时也不会重复写入。六位 SAS
仅在等待批准时进入无障碍树，并按六个独立 ASCII 数字朗读。两项 JVM 测试会拒绝不一致
状态和畸形 SAS 投影；维护者 fail-closed 门禁守住阶段/倒计时拆分，并禁止主动
accessibility announcement。该次改进使 Android 测试库存增至 234 项；这些只是离线证据。

The Android build baseline now retains min API 26 while compiling and targeting
API 36 with Build Tools 36.0.0, AGP 8.12.2, JDK 17, and a SHA-256-pinned Gradle
8.14.5 wrapper. `DroidMatchScreen` applies system-bar and display-cutout insets
only on API 35+, while API 26–34 keep the platform-owned safe area. The product
Activity's dedicated no-ActionBar theme removes the title duplicated by the
screen itself, preserving the first secure-USB action on compact API 26 displays
with accessibility font scaling. Equal-width action buttons share the taller
label's measured height so a second scaled/localized line is not clipped and the
paired control is not left shorter; device instrumentation checks both rows,
outer action bounds, measured text/padding height, and the final control after a
full scroll. The release
merged-manifest check freezes the theme reference. This closes the known target-SDK
and edge-to-edge drift locally, but it adds no formal API 35/36 device evidence.

中文：Android 构建基线保留最低 API 26，并升级为 compile/target API 36、Build Tools
36.0.0、AGP 8.12.2、JDK 17 与带 SHA-256 固定的 Gradle 8.14.5 wrapper。
`DroidMatchScreen` 只在 API 35+ 叠加 system bar/display cutout inset，API 26–34
继续由系统保留安全区。产品 Activity 的专属 no-ActionBar 主题会移除与页面标题重复的
系统标题栏，避免 API 26 小屏配合无障碍字体缩放时把首个安全 USB 操作挤出首屏。
并排按钮保持等分宽度并共同采用较高标签的实测高度，instrumentation 同时校验两组操作
等高、操作外框、文字/内边距所需高度，以及滚动到底后的最终操作，避免缩放或本地化后的
第二行被裁切或与较矮按钮错位；release 合并 manifest 检查固定该主题引用。
已在本地收口 target SDK 与 edge-to-edge 漂移，但这不新增 API 35/36 正式真机证据。

Current release UI accessibility inspection found that SwiftUI exposed raw SF
Symbol identifiers for decorative empty states and device-summary metrics. The
product now hides only redundant imagery across session-required/empty states,
headers, banners, summary/diagnostic cards, and named thumbnails/previews. Each device
metric is one value-plus-label element; file/media selection and sort choices
publish localized selected/not-selected values; icon-only row actions have
explicit labels; and transfer direction remains a meaningful localized image
label. Maintainer fail-closed cases guard those interactive seams, the Mac
localization inventory is 299 referenced keys, and release UI reinspection
confirms the raw summary symbols are absent. This is local UI evidence, not a
physical-device or distribution claim.

中文：release UI 无障碍巡检发现 SwiftUI 会把空态和设备统计中的纯装饰 SF Symbol
内部名称暴露给 VoiceOver。当前会话前置/空态、页头、提示条、统计/诊断卡和已有名称的
缩略图/预览只隐藏冗余图像；每项设备统计合并为“值、标签”，文件/媒体选择和排序公开本地化
“已选择/未选择”，图标行操作有明确标签，传输方向则保留为有意义的本地化图像标签。
维护者 fail-closed 用例守住这些交互接缝，Mac 本地化库存为 299 个已引用键，release UI
复检也确认原始统计 symbol 已消失。这些只是本地 UI 证据，不新增真机或分发声明。

Current Mac build reproducibility closes a divergence where the Swift test runner
could recover from an unwritable home module cache and a transient CLT arm64/SDK
mismatch while the product builder could not. Both now source one compatibility
boundary and accept arm64e only after paired target probes. The locally observed
macOS 26.5 `iconutil` encoder also rejected a valid iconset that its decoder had
extracted from an existing ICNS. Product assembly now validates ten exact RGBA PNG
renditions, writes explicit modern ICNS chunks without overwrite, and requires the
platform decoder to reopen the container before signing. Offline default/fallback,
packer, publication, and no-clobber tests pass, and a real dirty release App build
succeeds. Release UI inspection additionally removed two obsolete Files/Diagnostics
future-wiring placeholders; all inactive surfaces now describe only the actual
authentication prerequisite. This is local build/UI evidence, not a physical-device
or distribution-signing claim.

中文：当前 Mac 构建可复现性已消除一项分歧：Swift 测试 runner 能绕过不可写的 home
module cache 与短期 CLT arm64/SDK 不匹配，产品 builder 此前却不能。两者现共用一个兼容
边界，且只有成对 target probe 证明后才接受 arm64e。本机 macOS 26.5 的 `iconutil`
encoder 还会拒绝其 decoder 从既有 ICNS 解出的合法 iconset；产品组装现严格验证十个
RGBA PNG rendition，以 no-clobber 方式写入明确的现代 ICNS chunk，并要求平台 decoder
在签名前重新打开。默认/回退参数、packer、发布事务和 no-clobber 离线测试均通过，真实
dirty release App 也已构建成功。release UI 检查还移除了 Files/Diagnostics 两处过期的
未来接线占位；全部未认证页面现只说明真实认证前置条件。这些只是本地构建/UI 证据，
不新增真机或分发签名声明。

Current Mac directory metadata hardening no longer publishes arbitrary
provider MIME strings into Presentation. `DirectoryListingEntry` canonicalizes
optional MIME through a single Core boundary: restricted ASCII type/subtype values
are lowercased and capped at 127 bytes, the two product-owned virtual labels are
explicitly allowlisted, and malformed or oversized input degrades to nil without
dropping the valid row. MIME remains descriptive only; path identity, read/write
capabilities, and operation admission are unchanged. Existing directory-codec
evidence now covers canonicalization, provider directory MIME, control/bidi,
parameters, and length rejection; the Swift inventory remains 420. This is local
evidence only.

中文：当前 Mac 目录 metadata 加固不再把任意 provider MIME 字符串发布到
Presentation。`DirectoryListingEntry` 通过单一 Core 边界规范可选 MIME：受限 ASCII
type/subtype 统一小写并限制为 127 字节，两个产品自有虚拟标签显式列入白名单，畸形或
超长输入降级为 `nil` 而不会删除有效条目。MIME 仍仅是描述信息；path identity、读写
能力与操作准入不变。既有目录 codec 证据现覆盖规范化、provider 目录 MIME、
control/bidi、参数与长度拒绝；Swift 测试库存仍为 420。这些仍只是本地证据。

Current transfer-row privacy minimization no longer publishes a raw local
basename or an unused full `dm://` remote path. Presentation derives one bounded,
spoofing-safe basename through `ProductDisplayText`; SwiftUI rows and opt-in system
notifications consume that same value, while actions remain keyed by job UUID and
Core retains exact paths for ownership/resume. Existing presentation and
notification-policy tests now cover control/bidi/zero-width filtering, absence of
remote-path state, unchanged action identity, and safe terminal-event names. The
Swift inventory remains 420; this is local evidence only.

中文：当前传输行隐私最小化不再发布原始本地 basename 或未使用的完整 `dm://` 远端
路径。Presentation 只通过 `ProductDisplayText` 派生一个有界、抗伪装 basename；
SwiftUI 行和 opt-in 系统通知共用该值，动作继续按 job UUID，Core 保留精确路径用于
所有权与恢复。既有展示/通知策略测试现覆盖 control/bidi/零宽过滤、远端路径状态缺席、
动作身份不变与安全终态事件名称。Swift 测试库存保持 420；这些仍只是本地证据。

Current cross-platform external-name hardening consolidates Mac ADB,
pairing/trust/session, diagnostics, and remote-entry labels behind bounded
`ProductDisplayText`, and extends Android's existing `ProductDisplayName` to SAF
grant rows and release confirmation. Stable device/pairing/path/root identities
remain separate from display text. Mac also replaces the Core pairing value in
Published state with a minimal safe label plus SAS, excluding the device identity
fingerprint. Mac now defaults to 120 Unicode scalars (240 for remote entries) and
Android caps output at 120 code points; both reserve an in-bound ellipsis for real
visible truncation rather than accepting an unbounded or silently shortened label.
Existing Swift and JVM regressions cover malformed labels, supplementary-plane
boundaries, fallback, unchanged raw storage/transcript identity, and the minimal
pairing shape, so the inventories remain 420 and 234; this is local evidence only.

中文：当前跨端外部名称加固将 Mac 的 ADB、配对/信任/会话、诊断和远端条目名称
统一收敛到有界 `ProductDisplayText`，并把 Android 既有 `ProductDisplayName` 扩展到
SAF 授权行与移除确认。稳定设备/配对/path/root 身份仍与展示文本分离。Mac Published
状态也不再直接持有 Core 配对值，而只发布安全名称与 SAS，排除设备身份指纹。既有
Mac 默认限制 120 个 Unicode 标量（远端条目 240），Android 限制 120 个 code point；
两端都为真实可见截断在上限内保留省略号，不再接受无界或静默缩短的标签。既有
Swift/JVM 回归现覆盖畸形名称、补充平面边界、fallback、原始存储/transcript 身份不变
与最小配对形状，测试库存保持 420/234；这些仍只是本地证据。

Current Android trust-UI hardening no longer renders Mac-supplied names as raw
security-sensitive display text. `ProductDisplayName` creates one UI-only NFC
projection, collapses whitespace, removes control/format/surrogate code points,
and provides a fixed fallback; first-pairing approval and persisted paired-Mac
metadata both consume it, while the authenticated transcript, encrypted record,
SAS, and pairing-ID revoke target remain unchanged. Existing approval-controller
and paired-device-manager JVM tests now cover bidi/zero-width/control filtering,
normalization, whitespace folding, fallback, and unchanged revoke identity, so
that increment left the Android inventory at 234.

中文：当前 Android 信任界面不再把 Mac 提供的名称直接作为安全敏感展示文本。
`ProductDisplayName` 生成唯一 UI-only NFC 投影，折叠空白、移除控制/format/surrogate
码点并提供固定 fallback；首次配对批准与已持久化可信 Mac metadata 都消费该投影，
认证 transcript、加密记录、SAS 与 pairing-ID 撤销目标均不改变。既有批准 controller
和可信设备 manager JVM 测试现覆盖 bidi/零宽/控制字符过滤、归一化、空白折叠、
fallback 与撤销身份不变，因此该次改进后 Android 测试库存保持 234。

Current Mac trusted-device recovery hardening distinguishes a Keychain failure
that has completed from a Security.framework request that remains outstanding
after the five-second UI deadline. The passive display query uses a non-interactive
`LAContext`, so an item that would require authentication fails instead of opening
UI. The outstanding state keeps the single-flight boundary, explains that no prompt
will appear, suggests reopening DroidMatch, and exposes Try Again only after the old
request retires; an invalidated stale request still cannot republish pre-revoke rows.
Three MainActor regressions cover acceptance, duplicate rejection, late recovery,
mutation invalidation, and reopened admission; one direct Core query regression
brought the then-current Swift inventory to 459. A further credential-selection
regression proves one current-item read, zero reconnect writes, one shared
`LAContext` across bounded legacy reads, and complete selector backfill. Fresh
pairing now uses atomic add-only provisional publication, rejects every duplicate
pairing ID without reading or updating the existing item, and returns its newly
saved Core credential directly to the immediate authenticated
proof, so it performs no secret read. The same coordinator regression also obtains the
transfer scheduler twice while the store's secret-read count remains one: the
same-generation retry gate takes ownership of the credential already proven by
the authenticated session, and teardown still clears any pre-assembly reference.
The then-current Swift inventory remained 460.

中文：当前 Mac 可信设备恢复加固会区分“Keychain 查询已失败收敛”和“超过 5 秒界面
期限后 Security.framework 请求仍未返回”。被动展示查询使用禁止交互的 `LAContext`，
需要认证的记录会令查询失败而不是弹窗。等待态继续遵守单飞边界，说明不会弹窗并提示重开
DroidMatch，且只在旧请求退场后才提供“重试”；已被撤销操作作废的旧请求仍不能重新发布
撤销前的行。三项 MainActor 回归覆盖准入、重复拒绝、迟到恢复、mutation 作废与重新开放，
一项 Core 精确查询回归使当时 Swift 测试库存增至 459。后续凭据选择回归证明当前记录只读
目标机密一次、重连写入为零，并证明多条旧记录的有界读取复用同一个 `LAContext` 并完整
回填 selector。首次配对以原子 add-only 方式发布 provisional 凭据，任何重复 pairing ID 都不读取或
更新既有记录，并把刚保存的 Core 凭据直接交给随后的认证 proof。同一 coordinator 回归还会连续取得两次传输
scheduler，并证明存储机密读取计数保持 1：同 generation retry gate 接管认证会话已经证明的
凭据，teardown 仍会清除 assembly 前的临时引用。当时 Swift 测试库存保持 460。

Transactional App publication can replace the on-disk bundle without replacing
the code already mapped into a running process. One App-lifetime AppSupport
monitor captures the vnode already mapped for dyld image zero through
`proc_pidinfo` and polls the published path every two seconds even with no window.
Replacement, removal, or a
non-regular node emits one irreversible callback that closes discovery,
trusted-device, and session model entry points, cancels or generation-rejects
late publication, uses the existing safe disconnect, removes stale window
content, and blocks global refresh. It never reads Keychain state or launches a
new process. A process-owned active-window lease set prevents one closing window
from stopping another and rejects future leases after invalidation. One monitor
lifecycle/replacement/removal/non-regular test, one multi-window lease test, and
three model-gate tests bring the current Swift inventory to 465; a tested M0
source contract binds the high-risk App and model wiring.

事务化 App 发布可以替换磁盘 bundle，却不能替换运行进程已映射的代码。App 生命周期级
AppSupport monitor 现通过 `proc_pidinfo` 保存 dyld image zero 已映射 vnode 的
device/inode 身份并每两秒复核发布路径，
没有窗口时也继续运行。替换、移除或非普通节点只发送一次不可逆回调，使 discovery、可信
设备和 session 模型入口失效，取消或以 generation 拒绝迟到发布，进入既有安全断开、移除
旧窗口内容并阻塞全局刷新。进程级活跃窗口租约避免关闭一个窗口误停另一个窗口，并在失效后
拒绝新租约。该路径不读取 Keychain，也不启动新进程。一项 monitor 生命周期/替换/移除/非普通节点
测试、一项多窗口租约测试和三项模型 gate 测试使当前 Swift 库存增至 465；带负向测试的 M0
源码契约固定这些高风险 App/模型接线。

Current Android launcher recovery hardening no longer turns an unreadable
paired-Mac catalog into a visible zero count. Pure `ProductReadiness` policy
covers all four paired-catalog/SAF-catalog availability combinations; the paired
section is a polite live region with a fixed explicit retry, matching the SAF
recovery surface without exposing credential IDs or platform exceptions. The
existing JVM readiness test now covers the four summary states, so that launcher
increment left the Android inventory at 234.

中文：当前 Android 启动器恢复加固不再把不可读的已配对 Mac 目录显示为零。
纯 `ProductReadiness` 策略覆盖“配对目录/SAF 目录”四种可用性组合；配对区域现为
polite live region，并提供与 SAF 恢复面一致的固定显式重试，不暴露凭据 ID 或平台
异常。既有 JVM readiness 测试扩展覆盖四种摘要状态，该次 launcher 改进后 Android 测试库存保持 234。

Current persistence-failure admission now fails at the product interaction
boundary, not after a native panel has collected input. `TransferQueueModel`
makes unconfirmed/unhealthy/retrying persistence, bulk completed-history
cleanup, and new submission mutually exclusive; file/media toolbar, row, grid,
preview, drop, and upload-only actions all consume that state while shared
chrome exposes a local retry action. Browsing and remote mutations remain
independent. Existing controlled-suspension tests now prove retry/cleanup
overlap and post-failure submission cannot reach the data source, so the Swift
inventory remains 420.

中文：持久化故障现在会在产品交互边界直接阻止准入，而不是等原生面板收集完输入后
才失败。`TransferQueueModel` 让首次权威状态未确认、不健康/正在恢复的持久化、已完成
历史批量清理与新提交彼此互斥；文件/媒体工具栏、行、网格、预览、拖放和仅上传入口都
消费同一状态，共享 chrome 就地提供恢复动作，浏览与远端 mutation 仍独立可用。既有
可控挂起测试现证明恢复/清理重叠及故障后的新提交都不会到达数据源；Swift 测试库存
保持 420。

Current product transfer admission now has one MainActor single-flight across
single/batch downloads and uploads from both file and media surfaces. The lease
is acquired before bookmark, manifest, or scheduler data-source work and is
released with structured cleanup; a concurrent call returns without reaching
the data source, while already accepted jobs retain scheduler concurrency. The
App observes the same state to disable search, selection, row/context actions,
navigation, and media switching, revalidates native-panel completions, and
subtracts only accepted batch indices from current selection. One controlled-
suspension regression holds the first item of a two-download batch, proves
cross-kind duplicate rejection before data-source side effects, then proves the
second batch item still proceeds; the Swift inventory remains 420.

中文：当前产品传输准入在 MainActor 上共用一个单飞闩锁，覆盖文件与媒体页的
单项/批量下载和上传。闩锁会在 bookmark、manifest 或 scheduler 数据源工作前取得，
并通过结构化清理释放；并发调用不会到达数据源，已接受任务仍保留 scheduler 并发。
App 观察同一状态以禁用搜索、选择、行/右键动作、导航与媒体切换，在原生面板回调时
重新校验，并只按已接受批量索引从当前选择移除对应项。一项可控挂起回归把两项下载
批次的第一项停在数据源，证明跨类型重复提交会在副作用前被拒绝，随后证明第二项仍会
继续；Swift 测试库存保持 420。

Current multi-download admission guidance now matches the queue's independent
persistence contract. Unsafe duplicate or existing destinations still reject
the whole selection before submission, while a later zero/partial admission
uses distinct fixed localized copy and leaves accepted work visible in
Transfers. Presentation returns only accepted request indices plus job IDs, so
the App removes accepted inputs from selection without publishing paths or
filenames. One direct MainActor regression forces an accepted/rejected/accepted
sequence, verifies indices and stable submission order, and proves that accepted
job IDs are not discarded, bringing the then-current Swift inventory to 419.

中文：当前多选下载准入指引已与队列的独立持久化契约对齐。不安全的
重名或已存在目标仍在提交前整批拒绝；后续若全部或部分未被接受，使用
不同的固定本地化文案，已接受任务仍留在“传输”中。Presentation 只返回
已接受的请求索引与 job ID，App 因此可在不发布路径或文件名的情况下只保留
未接受输入的选中状态。一项 MainActor 直接回归强制“接受/拒绝/接受”序列，
验证索引、稳定提交顺序且已接受 job ID 不会被丢弃，使当时的 Swift 测试库存
增至 419。

Current transfer-failure guidance keeps the queue actionable without widening
its privacy boundary. Core derives a typed reason only from exact scheduler
labels retained for persistence compatibility; unknown strings, appended
provider text, and path-bearing variants produce no category. Presentation
groups those codes without retaining the source label, and the App renders only
fixed localized guidance for retrying, failed, or interrupted rows. Two Core
tests cover every emitted label plus malicious extensions, and two Presentation
tests cover every product category, state bounding, and reflection redaction,
bringing the Swift inventory to 418.

中文：当前传输失败指引在不扩大隐私边界的前提下让队列可操作。Core 只从为持久化
兼容保留的精确 scheduler 标签派生类型化原因；未知字符串、附加 provider 文本或含
路径变体都不会形成分类。Presentation 分组时不保留来源标签，App 仅在重试、失败或
中断行展示固定本地化指引。两项 Core 测试覆盖全部已发出标签和恶意附加内容，另两项
Presentation 测试覆盖全部产品分类、状态限制与反射脱敏，使 Swift 测试库存增至 418。

Current queue-history cleanup hardening adds a stable-order “Clear Completed”
path after multi-file submission. It snapshots only `completed && canRemove`
rows, excludes any job with an outstanding UI action, and sends each removal
through the existing independent scheduler/AppSupport persistence boundary.
Failed, cancelled, interrupted, and still-unwinding rows remain visible;
unhealthy persistence blocks bulk admission, duplicate same-job actions are
rejected, and partial removal is reported with exact counts rather than an
optimistic row deletion. Three direct MainActor tests cover eligible-row/order
selection with partial failure, suspended concurrent duplicate admission, and
the persistence-health fail-closed gate, bringing the Swift inventory to 414.

中文：当前队列历史清理加固为多文件提交后的“清除已完成”提供稳定顺序路径：只快照
`completed && canRemove` 行，排除已有 UI 动作尚未返回的 job，并让每项移除继续通过
既有独立 scheduler/AppSupport 持久化边界。失败、取消、interrupted 与仍在退场的行
保持可见；持久化不健康时拒绝批量准入，同 job 重复动作被拒绝，部分移除以精确计数
披露而不是乐观删除行。三项 MainActor 直接测试覆盖带部分失败的准入/顺序、受控挂起
期间的并发重复准入，以及持久化健康 fail-closed 门禁，使 Swift 测试库存增至 414。

Current product-upload selection hardening gives the native picker and Finder
drop one AppSupport-owned admission policy. It preserves caller order, caps a
batch at 100, rejects directories/symlinks/non-files, folds canonical form,
case, and width before duplicate-name checks, and reuses the exact provider and
MediaStore filename contract. AppSupport still registers one bookmark and Core
still performs no-follow identity validation per accepted item; the UI now
states that partial admission leaves accepted jobs in Transfers. Six direct
tests cover order, bounds, duplicates, file kind, media type, and unsafe names,
bringing the then-current Swift inventory to 411.

中文：原生选择面板与 Finder 拖放现共用 AppSupport 层上传选择策略：保持调用顺序、
限制 100 项、拒绝目录/符号链接/非文件，并在名称重复检查前统一 canonical form、
大小写与宽度，同时复用精确 provider/MediaStore 文件名契约。每个已接受项目仍由
AppSupport 独立登记 bookmark，并由 Core 以 no-follow 身份复核；部分入队时界面会说明
已接受任务保留在“传输”中。六项直接测试覆盖顺序、上限、重名、文件类型、媒体类型
和不安全名称，使当时 Swift 测试库存增至 411。

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
inventory at that point to 320.

中文：`DeviceSessionModel` 现仅在认证后的全部依赖成功后才发布浏览、诊断、传输队列
与会话信息；当前 generation 的依赖失败会与显式断开复用同一可等待 teardown，先完成
Core 清理再发布失败，并阻塞替换连接直至清理结束。五项聚焦测试覆盖已认证重连与配对后
错误、内部取消、替换顺序和断开去重，使当时 Swift 测试总数增至 320。

Current async-control and browser-liveness hardening classifies cancellation by
send admission and operation safety. Admitted mutation/transfer-control work is
session-fatal on caller cancellation; admitted read-only control work retains its
request ID/deadline and validates/drains a late response. Per browser, background row thumbnails
use a four-active FIFO and a 64-entry / 8 MiB cache; hiding the browser clears queued
derivative work, preview, and cached bytes, while navigation preserves admitted
mutations and pagination cannot strand a preview. Nine focused regressions cover
pre-admission cancellation, late read-only drain/session reuse, malformed late
response teardown, enforcement of the cancelled read-only request's original
deadline, admitted-mutation teardown, bounded/stale thumbnail queuing, navigation
during an admitted mutation, same-path query refresh, and preview completion across
load-more. The current Swift inventory is 329.

中文：当前 async control 与浏览存活性收敛会按 send admission 与操作
安全性分类取消：已准入 mutation/传输控制在调用者取消时关闭会话，
已准入只读控制则保留 request ID/deadline 并校验、排空迟到响应。后台
每个浏览器的行缩略图使用最多四项活跃的 FIFO 和 64 项 / 8 MiB 缓存；浏览器隐藏时
清理排队派生任务、预览和缓存字节，导航保留已准入 mutation，
分页不会使预览永久停在 loading。九项回归测试覆盖准入前取消、只读迟到响应
排空/会话复用、畸形迟到响应 teardown、已取消只读请求的原 deadline 继续生效、
已准入 mutation teardown、有界/旧 generation 缩略图队列、mutation 期间导航、同 path
query 刷新，以及 load-more 期间预览完成；当前 Swift 测试总数为 329。

Current App Sandbox staging hardening treats the sibling staging node as
untrusted: an ordinary file or symbolic link at that path is rejected without
deleting it, following it, touching its target, or publishing a destination. From
the 204-test baseline, three handshake/idle tests, three lexical/symbolic-component
admission tests, two transfer-scoped staging-isolation tests, and this one
non-directory-node test add nine regressions and raise the Android unit inventory
to 213.

中文：当前 App Sandbox staging 加固会把 sibling staging 节点视为不可信输入：
该路径若是普通文件或符号链接则直接拒绝，不删除节点、不跟随链接、
不触及目标，也不发布 destination。从 204 项基线起，三项 handshake/idle、
三项词法/符号链接 component 准入、两项 transfer-scoped staging 隔离，加上本项
非目录 staging 节点测试，共新增九项回归，使 Android 单元测试总数增至 213。

Current local-recovery and provider-boundary hardening adds exact upload-source
identity, seven-entry local download namespace admission, cross-process destination
leases, locked partial ownership, bounded directory-query work, safe App Sandbox
staging cleanup, and paired-reconnect recency updates. Upload v2 binds size,
nanosecond mtime/ctime, filesystem, and inode to one no-follow descriptor;
non-zero v1 checkpoints fail closed. Download execution holds the security-scope
lease, pinned directory FD, parent-inode/case-aware process reservation, and
sorted persistent-inode advisory locks. Commit synchronizes a fixed `0600`
marker, publishes with `RENAME_EXCL` or validated `RENAME_SWAP`, and retains the
old destination in fixed `.droidmatch-replaced` until sidecar cleanup succeeds.
Earlier failure restores old target/candidate; the marker remains until a restored
checkpoint is durable; crash-left recovery entries force `interrupted`; inability
to prove rollback reports `commitUncertain`. Download/upload sidecars and private
queue/bookmark publication use fixed `.pending`/`.removing`, complete stat and
pinned-parent validation, EXCL/SWAP identity checks, and required file/directory
synchronization. Their fixed per-parent `.droidmatch-private-atomic-lock` is a
permanent zero-byte `0600` inode whose checked exclusive `flock` serializes
cooperating processes. Exact Android queries return an error-only bounded-capability
failure rather than silently truncate beyond the 10,000-entry retrieval horizon.
The virtual-root cursor additionally binds a stably ordered live root identity
and read/write capability snapshot, so grant or permission changes invalidate
the offset. Untrusted queue manifests reject excessive attempt/delay values,
and every resumed/retried increment plus jitter conversion is overflow-safe.
Unexpected coordination or cleanup nodes are preserved. The current inventory is
473 Swift tests and 242 Android JVM tests; these offline regressions add no
physical-device or release-signing evidence.
The takeover baseline therefore names 473 Swift tests and 242 Android unit tests/lint;
the older counts in the decomposition history remain milestone data.

中文：当前本地恢复与 provider 边界加固新增了上传源精确身份、七 entry 下载命名空间
准入、跨进程 destination lease、partial 独占锁、目录查询上限、App Sandbox staging
安全清理和配对最近使用更新。下载执行期持有 security scope、固定目录 FD、按父目录
inode/卷大小写语义键控的进程级 reservation 与按序取得的持久 inode advisory locks。
提交同步固定 `0600` marker，按目标是否存在走 `RENAME_EXCL` 或经验证的
`RENAME_SWAP`，并把旧目标保留在固定 replaced entry，直到 sidecar 清理成功。更早失败
会恢复旧目标与 candidate，且 marker 会保留到恢复 checkpoint 已持久化；崩溃 recovery
entry 会转为 `interrupted`，无法证明回滚才报 `commitUncertain`。sidecar 与私有
queue/bookmark 使用固定 `.pending`/`.removing`、完整 stat、parent 复核、EXCL/SWAP
身份校验和强制文件/目录同步；每个 parent 的永久零字节 `0600`
`.droidmatch-private-atomic-lock` 以经过身份复核的独占 `flock` 串行协作进程。Android
精确查询越过 10,000 entry 检索范围时返回仅含稳定能力错误的响应，不再静默截断。
虚拟 root cursor 还绑定稳定排序的实时 root 身份与读写能力快照，授权或权限变化会使
offset token 失效；不可信 queue manifest 会拒绝过大的 attempt/delay，恢复与重试的
递增和 jitter 转换也都显式防溢出。
异常节点会保留。当前库存为 473 项 Swift 测试与 242 项 Android JVM 测试；这些只属于
离线回归，不新增真机或发布签名证据。

Current build/release hardening removes two stale-result windows. DMG publication
fully synchronizes owner, a root/parent-bound marker, and `building` state in a
private process-instance-scoped initializer before `RENAME_EXCL` publishes the
stable transaction. Owner identity includes PID, boot session, and process start
time, so PID reuse cannot masquerade as the interrupted builder;
offline tests cover every partial-initialization shape, an active initializer, a
real hard kill, and forged/unknown-node rejection. Release readiness re-reads local
HEAD and clean worktree state after its slow artifact and hosted checks. Bare
relative DMG outputs are resolved to an absolute parent before directory sync.
Candidate validation preserves the complete static/signature/entitlement boundary
while deferring only the private-transaction-path `adb version` launch. The final
published path then receives the complete production verifier before completion,
with replacement rollback or first-publication withdrawal on failure. Published-App
and mounted-DMG validation retry at most twice only for the exact
`embedded adb is not runnable` result, which macOS can return briefly for a freshly
published or mounted bundle.
A valid embedded adb vendor signature is preserved instead of being replaced by
a fresh ad-hoc identity; only a genuinely unsigned custom adb is signed locally,
an invalid existing signature is rejected, and the
outer App resource seal binds its exact bytes. Every other bundle failure remains
immediate, and retry exhaustion still blocks publication.

The App builder no longer runs `install -d` against a caller-owned existing output
parent. That command was observed attempting to change `/private/tmp` to `0755`,
which could remove sticky/shared-directory permissions outside a sandbox. Missing
parents are still created, while an offline successful-build regression proves a
non-default existing mode is unchanged; a real release build under `/private/tmp`
passes without the chmod attempt.

中文：当前构建/发布加固关闭了两个陈旧结果窗口。App 与 DMG 的 owner 会绑定 PID、
boot session 与进程启动时刻，PID 复用不会伪装成中断的 builder。DMG 会在进程实例
作用域的私有 initializer 中完整同步 owner、绑定 root/parent 的 marker 与 `building` state，再以 `RENAME_EXCL`
发布稳定事务；离线测试覆盖每种初始化残片、活跃 initializer、真实强杀及伪造/未知节点
拒绝。发布预检会在慢速产物与托管检查结束后重新读取本地 HEAD 和干净工作树。裸相对
DMG 输出也会在目录同步前解析为绝对 parent。
候选 App 会验证完整静态树、签名与 entitlement，只延后私有事务路径中的 `adb version`；
最终路径会在标记完成前执行完整生产 bundle verifier，失败时替换发布恢复旧 App，首次发布
则撤回。只有新发布或新挂载的 App 精确返回 `embedded adb is not runnable` 时才最多额外重试两次。有效的内置 adb 厂商签名保持不变，
只有完全未签名的自定义 adb 才补本地签名；已有但无效的签名直接拒绝，外层 App resource
seal 仍绑定其精确字节。其他 bundle
错误立即失败，重试耗尽也会阻止产物发布。

App 构建器不再对调用方已有输出父目录执行 `install -d`。该命令曾被真实观察到尝试把
`/private/tmp` 改成 `0755`，在沙箱外可能移除 sticky/共享目录权限。缺失父目录仍会创建；
离线成功构建回归证明已有非默认 mode 不变，真实 `/private/tmp` release 构建也不再尝试 chmod。

The machine-checked markers above are the current-tree authority: the largest
production source is `AsyncTransferScheduler.swift` at 743 lines, the largest
test source is `DmFileProviderSafTest.java` at 737 lines, the largest tool is
`check-maintainer-contract.py` at 800 lines, and the inventory is 473/242. Counts and
sizes embedded later in the decomposition history describe those earlier
milestones even where their original prose used “current.”

中文：以上机器校验 marker 是当前工作树的权威值：最大生产源码为 743 行的
`AsyncTransferScheduler.swift`，最大测试源码为 737 行的
`DmFileProviderSafTest.java`，最大工具为 800 行的 `check-maintainer-contract.py`，
测试库存为 473/242。下方拆分历史中嵌入的
数字均描述当时里程碑，即使原段落沿用了“current/当前”措辞，也不覆盖上述当前值。

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Tool script size | **Unified budget enforced** | Every handwritten shell/Python file under `tools/` now shares the 800-line default with no exception. The discovered 3,277-line `run-m1-device-smoke.sh` is now a 673-line final orchestrator over explicit 150-line usage, 723-line option/validation, 384-line device-control, 386-line privacy/evidence, 363-line App Sandbox probe, 541-line result-log, and 128-line cleanup contracts. The largest tool is the 800-line maintainer-contract checker. Several release/evidence scripts remain close to the ceiling, so line count is a guardrail rather than proof of architectural quality. |
| Large source files | **Unified budget enforced** | Every handwritten production and test Swift/Java/Kotlin file is at most 800 lines, with no exception; the largest production file is now the 743-line Mac `AsyncTransferScheduler.swift` and the largest test file is now the 737-line Android `DmFileProviderSafTest.java`. The former 755-line atomic download writer now keeps descriptor and transaction orchestration in 480 lines, while a 274-line stateless partial-file boundary owns no-follow opening, single-link validation, non-blocking `flock`, and descriptor/name inode reconciliation without retaining writer state; all 18 focused atomic-download tests pass unchanged and the then-427-test inventory was unchanged. The former 783-line product file-browser parent now keeps SwiftUI state, native panels, mutations, and queue submission in 682 lines; unchanged list/grid rendering lives in a 140-line stateless state/actions component, a 93-line pure Presentation value owns selection invariants, and a 135-line AppSupport policy fail-closes native-panel completion and shared single/batch download planning. Five direct tests raised the then-current Swift inventory to 425; one direct mutation-runner test brought the then-current Swift inventory to 426; one direct completion-policy test brought the then-current inventory to 427; four execution-policy tests brought the next inventory to 431; three selection-state tests brought the then-current inventory to 434; three thumbnail-state tests brought the then-current inventory to 437; one direct one-shot state test brings the current inventory to 438. The former 788-line private atomic writer now keeps transaction orchestration in a 371-line file and unchanged POSIX proof helpers in a 425-line same-module extension; eight focused filesystem/cross-process tests pass and the then-420-test Swift inventory was unchanged. The former 662-line Android provider facade now retains composition, the SAF cache lifetime, and process-wide upload leases in 415 lines; its unchanged MediaStore, SAF, and App Sandbox port methods/defaults live in 100/104/96-line package-private interfaces, concrete catalogs no longer implement facade-nested contracts, and that extraction left the then-180-test Android inventory unchanged. The former 586-line Mac local-frame server fixture now keeps listener/echo/general request scenarios in a 367-line base and moves its unchanged Hello/paired-authentication methods into a 225-line same-type extension; listener state, function visibility, wire order, and the 311-test Swift inventory remain unchanged. The former 592-line Android provider-transfer suite now separates its 21 unchanged tests into 211-line App Sandbox mutation/listing, 289-line App Sandbox transfer, and 121-line MediaStore/generic transfer suites; production visibility and the 180-test Android inventory remain unchanged. The former 601-line ADB-endpoint suite now separates its nine unchanged tests into 208-line admission, 164-line lifecycle, and 20-line log-privacy suites over one 249-line socket/latch support boundary; production visibility and the 180-test Android inventory remain unchanged. The former 647-line directory-browser model suite now separates its then-17 tests into a 258-line pagination/navigation/lifecycle suite and a 243-line mutation/media/presentation suite, sharing one 157-line actor-probe/fixture boundary; only test-target access changed, while MainActor behavior, test bodies, call ordering, production visibility, and the 293-test inventory remain unchanged. The former 658-line upload-coordinator suite now separates its three 220-line behavior tests from a 445-line local TCP recovery-server/support boundary; only test-target access changed, while production visibility, test bodies, wire timing, and the 293-test inventory remain unchanged. The former 674-line transfer-queue presentation suite now separates its 14 tests into a 90-line pure presentation/notification policy suite, a 273-line MainActor model suite, and a 75-line scheduler-adapter suite, all sharing one 251-line probe/support boundary; only test-target access changed, while production visibility, test bodies, and the 293-test inventory remain unchanged. The former 702-line product-session coordinator suite now separates its ten 359-line behavior tests from a 347-line probe/support boundary; only test-target access changed, production visibility and the 293-test inventory are unchanged. The former 727-line mixed-transfer server now keeps its 386-line listener/control plus happy path separate from a 246-line cancellation/reuse extension and a 109-line resume-failure extension; all extend the same server and share its existing state/wire helpers without copying lifecycle state or changing the then-293-test inventory. The former framed transfer extension is split into 209-line Control, 181-line Download, and 356-line Upload protocol-role extensions over the same server type, without copying live state or changing method bodies. Transfer-queue persistence evidence is split into a 128-line store format/permission contract and a 494-line scheduler restoration/fail-closed suite, sharing a 126-line deterministic fixture boundary without changing the then-275-test Swift inventory. Android dispatcher download evidence is now split into a 437-line resume/window/error/concurrency suite and a 272-line cancel/pause lifecycle suite, while heartbeat coverage lives with the 467-line general dispatcher suite; the then-177-test Android inventory was unchanged. The former 2,526-line Mac frame/RPC fixture, 1,288-line multiplexer test, 1,173-line Android provider test, and 1,977-line dispatcher test are split by behavior/fixture ownership. Mac harness download and upload commands now live in separate 414/342-line files while remaining Core consumers. Android nonce/reconnect authentication is 295 lines and visible first pairing is 470 lines after pure limits/capability/payload policy moved to `RpcAuthenticationPolicy` and the two live paths received explicit owners; the former 620-line transfer handler now keeps active chunk/ACK/cancel/pause/terminal-error teardown actions in 447 lines, while the 334-line `RpcTransferOpenHandler` owns open parsing, capability/concurrency admission, provider opening, and initial handle installation over the same sole registry; the MediaStore catalog retains resolver/URI/query/permission/cache/error/thumbnail/transfer/pending-row ownership after typed page/album/lookup/metadata cursor scanning moved to the stateless `MediaStoreCursorReader`; the SAF catalog retains live root/parent admission, listing/download/mutation, metadata validation, and per-chunk exact-tree authorization; `AndroidSafUploadOpener` owns authorized final/partial creation, exact child lookup, ACK-loss truncation, writer handoff, and pre-handoff cleanup, while the 61-line pure `SafUploadOpenPolicy` directly covers fresh/restart/resume plus partial kind/size decisions. Five policy tests raised the then-current Android unit inventory to 185; ten envelope-integrity and terminal transfer-lifecycle tests raised it to 195; five live-authorization tests raised it to 200; four media-permission/root-capability tests raised it to 204; three handshake/idle timeout policy and endpoint-wiring tests raised it to 207; three App Sandbox lexical-alias and symbolic-component admission tests raised it to 210; two transfer-scoped staging isolation tests raised it to 212; one non-directory staging-node test now rejects an ordinary file or symbolic link without deletion, traversal, or publication and raised the then-current Android unit inventory to 213. Scheduler request/persistence, coordinator/executor wiring, job execution event ordering, terminal-result calibration, local-endpoint projection, consumer delivery state, rate-expiry task ownership, session-end transition policy, and pause/resume/cancel and executor-unwind completion policies have explicit boundaries; the actor is now 699 lines; its 120-line pure execution policy validates retry attempt accounting, exact pre-write rollback, monotonic stable-total progress, and current rate expiry generation with four direct tests; its 152-line pure control policy mutates only records/FIFO and returns ordered post-persistence effects, with four direct tests; its 73-line actor-confined persistence state owns store I/O, coarse health, and the reload latch without retaining live records or publishing partial recovery; its 68-line pure completion policy mutates only the supplied record and returns paused/interrupted/terminal resolution; its 49-line actor-confined rate-expiry state replaces/cancels timer tasks without owning job records or publishing snapshots, pure shutdown/suspension record decisions return explicit effects, terminal outcomes/completion waiters/snapshot observers live in a separate actor-confined value, and the reusable execution probe lives with shared fixture construction. Scheduler behavior evidence is split into a 471-line retry/progress/terminal suite and a 247-line pause suite, sharing a 212-line fixture boundary without changing the then-275-test inventory. Multiplexer inbound response/stream application is grouped in a 236-line same-actor extension, leaving its lifecycle/send/transfer-admission core at 555 lines without copying route state. Product-session public values, protocols, and client seams live in `ProductDeviceSessionContracts`; the immutable 136-line `ProductTransferSchedulerAssembly` reloads the exact fingerprint-bound credential before deriving the local-access owner, persistence store, invalidatable gate, and access-leased executors without owning generation or live scheduler state; the 140-line `ProductTransferPersistenceLocation` owns the domain-separated private queue route plus atomic no-clobber migration and fail-closed collision/symlink handling; the 118-line actor-confined `ProductTransferSchedulerLifecycle` atomically owns the retry gate, published scheduler, and generation-bound build while rejecting stale build-ID/object-identity cleanup; ordered release of an atomically detached generation and its invalidatable retry-client gate live in `ProductDeviceSessionResources`. Five direct assembly tests plus four persistence-location tests raised the then-current inventory to 310 Swift tests, and the 573-line coordinator actor remains the sole owner of authentication state, generation validation, scheduler publication/readiness, and asynchronous detach/cleanup. Mixed-server lock state, framed-server readers/response values, pure transfer fixture helpers, and restored-execution readiness tests are isolated. The 682-line product file-browser parent remains the sole owner of SwiftUI state, panels, mutations, and queue submission after list/grid rendering moved to a stateless state/actions component, selection invariants moved to a 93-line pure Presentation value, and native-panel/download admission moved to a pure AppSupport policy. Its 628-line MainActor browser model retains published state, listing generations, navigation, derivative Tasks/previews/permission decisions, and path-gated outcomes; a 132-line pure thumbnail state owns generation/FIFO/active-key/failure/cache transitions, while the 157-line MainActor mutation runner owns the active remote-mutation Task and operation identity. Neither extracted boundary owns unrelated presentation or refresh policy. One direct test proves the runner latch rejects a second client call and reopens after completion, bringing the then-current Swift inventory to 426; one completion-policy test brought the then-current inventory to 427; four execution-policy tests brought the then-current inventory to 431; three selection-state tests brought the then-current inventory to 434; three thumbnail-state tests brought the then-current inventory to 437; one direct one-shot state test brings the current inventory to 438. One unreadable-but-writable root test proves no navigation/list request while retaining upload capability and raised the then-current Swift inventory to 315. Four real local TCP/RPC browser tests cover mutation/thumbnail encoding, capability gates, bounded embedded errors, malformed responses, pre-wire path validation, and post-error session reuse; that change raised the Swift inventory to 279. |
| Product transfer assembly credential source | **Current correction** | The historical size-decomposition narrative above predates the current credential handoff: `ProductTransferSchedulerAssembly` no longer reloads Keychain. It accepts the same-generation, already-proven Core credential, revalidates its fingerprint, and installs it in the invalidatable retry gate. |
| RPC deadline lifecycle | **Hardened with real TCP evidence** | Four tests hold real local TCP requests open to prove that control, download/upload open, and upload-ACK expiry return typed timeout failures and terminate the ambiguous multiplexed session. Deadline conversion saturates before `Double` to `UInt64` conversion, so even the largest finite timeout cannot trap at the rounded 2^64 boundary. That change raised the Swift inventory to 283. |
| M1 smoke orchestration | **Covered at the real TCP boundary** | Two tests drive the exact CLI wrapper over loopback TCP. The success path proves the ordered Hello, heartbeat, device info, canonical root listing, and diagnostics result; the failure path injects a recoverable remote application error and observes client EOF, proving the wrapper closes the session that the lower RPC layer intentionally leaves reusable. That change raised the Swift inventory to 285. |
| Transfer retry-session invalidation | **Deterministically covered** | Three tests exercise the product transfer gate: a real paired TCP handshake verifies the live endpoint/credential path, invalidation before connection rejects without invoking the connector, and an actor-held connector proves invalidation racing a completed connection closes that socket before returning cancellation. The seam is internal-only, while production retains the fixed lease endpoint and 10-second timeout. That change raised the Swift inventory to 288. |
| ADB forward lease lifecycle | **Fail-safe ownership covered** | Five focused tests cover preparation error normalization, device disappearance, same-device preparation exclusion, cancellation after forward allocation, and mismatched release. Release now validates the public capability before consuming the actor-private serial/port record, so the exact lease can still clean up after a mismatched attempt. `AdbDeviceDiscovery` owns only discovery and the dynamic loopback forward; authenticated RPC session ownership remains in `ProductDeviceSessionCoordinator`. That change raised the Swift inventory to 293. |
| Synchronous Mac networking | **Removed** | Every product and CLI operation uses the async session/router. The semaphore transport, synchronous RPC client, and implementation-specific tests are deleted; stable errors/results live in transport-independent files. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, the current-state contribution guide, optional PR handoff template, bilingual live docs, deterministic gates, 473 Swift tests, and 242 Android unit tests/lint reduce undocumented knowledge. CI rejects drift of takeover, physical-device, 800-line, PR-evidence, and bilingual-resource contracts. A focused live-document truth gate now owns required high-risk facts, requires the English/Chinese M1 status dates to match, requires both status pages to retain the protected direct-main tool fact and the domain-separated queue-route fact, and provides tested narrow semantic rejection for known-false SAF resume/cleanup and archived-device-evidence paraphrases; implementation seams remain a separate maintainer-contract check, and neither is presented as general semantic understanding. At the owner's explicit direction, Phase A permits no-PR fast-forward integration only after the exact candidate SHA receives all three hosted skeleton checks; administrator enforcement, main-tip revalidation, linear history, resolved conversations for optional PRs, and force-push/deletion bans remain. [GitHub Governance Baseline](github-governance.md) records the exact controls and the real second-maintainer Phase B. Ownership and release authority remain concentrated, and direct integration removes even the procedural PR boundary, so deterministic gates reduce bypass risk but cannot provide independent review. |
| macOS product App target | **Implemented; release evidence incomplete** | SwiftPM exposes a SwiftUI `DroidMatch` product with localized discovery, authentication, trusted-device revoke, browsing, independent media, transfers, persistent media-layout and opt-in privacy-bounded transfer notifications, a device-isolated queue, owner-scoped App-owned bookmark leases, ordinary/sandbox bundle assembly, and a mount-verified local DMG with checksum. Ordinary and sandboxed Slot C product authentication, browsing, bidirectional transfer, revocation, and forced-relaunch upload recovery are archived. Developer ID signing and notarization remain explicitly deferred and unverified. |
| Android product entry | **Secure onboarding and trust/authorization management implemented** | Product launcher `DroidMatchActivity` presents a tested top-level next-step summary and owns the paired-required endpoint, pairing approval, notification permission, paired-Mac list/revoke, user-triggered photo/video permission or reselection, and SAF root list/add/revoke. Pure media policy keeps API request sets, callback fallback, and legacy write support separate from platform actions; live root read capability is independent from write capability. Static hierarchy construction is isolated in `DroidMatchScreen`, which receives action callbacks but cannot perform security-sensitive operations itself. Revoking trust closes the active USB service before it can be reused. CI assembles an unsigned release APK, verifies the product launcher, and rejects the debug harness in its merged manifest. The media UI has local automated evidence but no archived physical pass; Android is not yet a local file browser or complete device-management UI. |

中文结论：生产与测试代码现已统一执行 800 行门禁；最大生产文件现为 743 行的 Mac `AsyncTransferScheduler.swift`，最大测试文件现为 737 行的 Android `DmFileProviderSafTest.java`。原 755 行原子下载 writer 现以 480 行保留 descriptor 与事务编排；274 行无状态 partial-file 边界负责 no-follow 打开、单链接校验、非阻塞 `flock` 及 descriptor/name inode 对账，且不保留 writer 状态；18 项原子下载专项测试原样通过，当时 427 项库存不变。原 783 行产品文件浏览器父视图现以 682 行持有 SwiftUI 状态、原生面板、mutation 与队列提交；未改行为的列表/网格渲染归入 140 行无状态 state/actions 组件，93 行 Presentation 纯值独占选择不变量，135 行 AppSupport 纯策略则 fail closed 复核面板完成与单项/批量下载规划。五项策略测试使当时 Swift 库存增至 425 项，三项选择状态测试使当时库存增至 434 项。原 788 行私有原子写入器现把事务编排保留在 371 行文件中，未改行为的 POSIX proof helper 归入 425 行同模块 extension；八项文件系统/跨进程专项测试通过，当时 420 项 Swift 测试库存未改变。原 662 行 Android provider facade 现以 415 行保留组装、SAF cache 生命周期与进程级上传租约；未改方法/default 的 MediaStore、SAF、App Sandbox 端口分别归入 100/104/96 行 package-private 接口，具体 catalog 不再实现 facade 内嵌契约，当时 Android 180 项单元测试总数不变。原 586 行 Mac local-frame server fixture 现把 listener/echo/通用请求场景保留在 367 行基类，并把未改正文的 Hello/配对认证方法移入 225 行同类型 extension；listener 状态、函数可见性、wire 顺序与 311 项 Swift 测试总数不变。原 592 行 Android provider-transfer 套件现把 21 项未改正文的测试拆为 211 行 App Sandbox mutation/listing、289 行 App Sandbox transfer 与 121 行 MediaStore/通用 transfer 套件；生产可见性和 180 项 Android 单元测试总数不变。原 601 行 ADB endpoint 套件现把九项未改正文的测试拆为 208 行 admission、164 行 lifecycle 和 20 行日志隐私套件，共享一个 249 行 socket/latch support 边界；生产可见性和 180 项 Android 单元测试总数不变。原 647 行 DirectoryBrowserModel 套件曾把当时 17 项测试拆为 258 行分页/导航/生命周期和 243 行 mutation/media/展示两组行为证据，共享一个 157 行 actor probe/fixture 边界；只调整测试 target 内部可见性，MainActor 行为、测试正文、调用顺序、生产可见性与 293 项 Swift 测试总数均未改变。原 658 行 upload coordinator 套件现把 3 项行为测试保留在 220 行文件中，并把本地 TCP 恢复服务器与同步 probe 归入 445 行共享 support；只调整测试 target 内部可见性，测试正文、wire 时序、生产可见性与 293 项 Swift 测试总数均未改变。原 674 行传输队列 Presentation 套件现把 14 项测试拆为 90 行纯展示/通知策略、273 行 MainActor 模型和 75 行 scheduler adapter 三组行为证据，共享一个 251 行 probe/support 边界；只调整测试 target 内部可见性，测试正文、生产可见性与 293 项 Swift 测试总数均未改变。原 702 行产品会话 coordinator 套件现拆为 359 行的 10 项行为测试和 347 行 probe/support 边界；只调整测试 target 内部可见性，生产可见性与 293 项 Swift 测试总数均未改变。原 727 行 mixed-transfer server 现拆为 386 行 listener/控制面与正常路径、246 行取消/复用 extension 和 109 行恢复失败 extension；三者扩展同一 server，并继续共享既有 state/wire helper，不复制生命周期状态，也未改变当时 293 项 Swift 测试。原 framed transfer extension 已按协议角色拆为 209 行 Control、181 行 Download 与 356 行 Upload 三个同类型 extension，未复制存活状态或修改方法体。transfer-queue persistence 证据现拆为 128 行的 store 格式/权限契约与 494 行的 scheduler 恢复/fail-closed 套件，共享 126 行确定性 fixture 边界，该次拆分未改变当时 275 项 Swift 测试。Android dispatcher 下载证据现拆为 437 行的续传/窗口/错误/并发套件与 272 行的取消/暂停生命周期套件，heartbeat 覆盖归入 467 行的通用 dispatcher 套件，Android 177 项测试数量不变。Mac harness 的下载/上传命令已拆成 414/342 行两个文件且仍只消费 Core。Android nonce/重连认证 handler 为 295 行、可见首次配对 handler 为 470 行，两者共享同一个进程级限速器；原 620 行 transfer handler 现以 447 行保留活动 chunk/ACK/cancel/pause/终止错误 teardown 动作，334 行 `RpcTransferOpenHandler` 则在同一个唯一 registry 上独占 open 解析、能力/并发准入、provider 打开与初始 handle 安装。MediaStore catalog 在无状态 cursor reader 承担 typed page/album/lookup/metadata 解码后，仍唯一持有 resolver、URI/query、实时权限、cache、错误映射、缩略图、传输与 pending row；SAF catalog 继续负责实时 root/parent admission、列表/下载/mutation、metadata 验证与逐 chunk 精确 tree 授权；`AndroidSafUploadOpener` 独占已授权 final/partial 创建、精确 child 查找、ACK-loss 截断、writer 交接和交接前清理，61 行纯 `SafUploadOpenPolicy` 直接覆盖 fresh/restart/resume 及 partial kind/size 决策，新增五项 policy 测试曾使当时 Android 单元测试增至 185；十项 envelope 完整性与终止性 transfer 生命周期测试使其增至 195；五项活动授权测试使总数增至 200；四项媒体权限策略/root capability 测试使其增至 204；三项 handshake/idle timeout 策略与 endpoint 接线测试使总数增至 207；三项 App Sandbox 词法别名与符号链接 component 准入测试使总数增至 210；两项 transfer-scoped staging 隔离测试使当时 Android 单元测试总数增至 212；一项非目录 staging 节点测试现会拒绝普通文件或符号链接，不删除、不遍历、不发布，并使当前总数增至 213。scheduler 的请求/持久化、coordinator/executor 装配、job execution 事件排序、终态结果校准、本地 endpoint 投影、consumer delivery state、速率过期 Task 所有权、session-end transition policy 与 pause/resume/cancel transition policy 及 executor 退场 completion policy 均已有明确边界，actor 现为 699 行；120 行纯 execution policy 以四项直接测试覆盖 retry attempt、精确写盘前回滚、总量稳定的单调进度与当前 rate generation 过期；152 行纯控制策略只修改 record/FIFO 并返回写盘后的有序副作用，四项直接测试覆盖控制策略；73 行 actor-confined persistence state 只持有 store I/O、粗粒度健康状态和 reload 闩锁，不保留 live record，也不会发布部分恢复结果；68 行纯 completion policy 只修改传入 record 并返回 paused/interrupted/terminal resolution；49 行 actor-confined rate-expiry state 只替换/取消 timer Task，不持有 job record，也不发布快照；纯 shutdown/suspension 状态决策只返回显式 effect，终态 outcome、完成 waiter 和快照 observer 归入另一 actor 隔离值，共享 execution probe 也已归入 fixture 支持文件。scheduler 行为测试现拆为 471 行 retry/progress/terminal suite 与 247 行 pause suite，共享 212 行 fixture 边界，该次拆分未改变当时 275 项 Swift 测试。multiplexer 的入站 response/stream 应用现归入 236 行的同 actor extension，生命周期、发送与传输 admission 核心降至 555 行且没有复制 route 状态。产品会话的公开值、协议与 client 测试接缝归入 `ProductDeviceSessionContracts`；136 行不可变 `ProductTransferSchedulerAssembly` 在派生匿名本地授权 owner、持久化 store、不可复活 gate 与带 lease 的执行器前重新校验精确指纹凭据，且不持有 generation 或 live scheduler；140 行 `ProductTransferPersistenceLocation` 独占域分离的私有队列路由、原子无覆盖迁移及冲突/符号链接 fail-closed 处理；118 行 actor-confined `ProductTransferSchedulerLifecycle` 原子持有 retry gate、已发布 scheduler 与 generation-bound build，并以 build ID/对象身份拒绝旧构建清理新资源；原子分离后的单代资源释放顺序和不可复活的 retry-client gate 归入 `ProductDeviceSessionResources`。五项直接 assembly 测试与四项持久位置测试使当时 Swift 测试总数升至 310，573 行 coordinator actor 继续独占认证状态、generation 校验、scheduler 发布/readiness 和异步 detach/cleanup。682 行产品文件浏览器父视图继续持有 SwiftUI 状态、面板、mutation 与队列提交；列表/网格渲染归入无状态 state/actions 组件，选择不变量归入 93 行 Presentation 纯值，原生面板/下载准入归入 AppSupport 纯策略；对应的 628 行 MainActor 浏览模型继续持有 Published 状态、listing generation、导航、派生 Task/预览/权限判断和按 path 应用结果；132 行纯缩略图状态独占 generation/FIFO/active-key/失败/缓存 transition，157 行 MainActor mutation runner 则独占活跃远端 mutation Task 与操作身份；两者都不持有无关展示或刷新策略；一项直接测试证明内部闩锁拒绝第二次 client 调用并在完成后重新开放，使当时 Swift 库存增至 426；一项 completion-policy 测试使当时库存增至 427；四项 execution-policy 测试使当时库存增至 431；三项 selection-state 测试使当时库存增至 434；三项 thumbnail-state 测试使当时库存增至 437；一项 one-shot 状态测试使当前库存增至 438。新增一项不可读但可写 root 测试证明不会导航或发送第二次 listing，同时保留上传能力，并使当时 Swift 测试总数增至 315。四项真实本地 TCP/RPC 浏览器测试现覆盖 mutation/thumbnail 编码、能力门禁、有界 provider 错误、畸形响应、发包前路径校验以及错误后的会话复用，该次改进使当时 Swift 测试总数增至 279。恢复执行 readiness 测试已拆入独立文件。存量巨石已按行为和 fixture 所有权拆分。单人维护风险仍只有部分治理；Mac 已接通认证会话、文件浏览、结构化诊断、持久双向队列和按认证 owner 隔离的 bookmark 租约，普通与 sandbox Slot C 产品认证、浏览、双向传输、撤销及强退后上传恢复均已有归档证据；Developer ID 签名与公证按当前决策暂缓且未验证。Android 已升级为安全连接 onboarding/status、用户主动触发的媒体权限与 SAF 授权管理入口；媒体 root 的实时读取能力与写入能力独立，产品媒体 UI 尚无真机归档，完整本地文件浏览体验仍未完成。

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

The same checker now covers every handwritten `tools/**/*.sh` and
`tools/**/*.py` file under the same 800-line ceiling with no exception. The
discovered 3,277-line `run-m1-device-smoke.sh` is now a 673-line final
orchestrator over explicit usage, option/validation, device-control,
privacy/evidence, App Sandbox probe, result-log, and cleanup helpers; every
helper also fits the default. Several build/evidence scripts still sit at
773–800 lines, so structural boundaries and behavior tests remain necessary;
line count alone does not prove good architecture.

中文：同一检查器现在以无例外的 800 行上限覆盖全部手写 `tools/**/*.sh` 与
`tools/**/*.py` 文件。新发现的 3277 行 `run-m1-device-smoke.sh` 已成为 673 行最终编排器，
usage、参数/校验、设备控制、隐私/证据、App Sandbox 探针、结果日志与清理均有独立 helper，
且全部满足默认上限。多个构建/证据脚本仍达到 773–800 行，因此结构边界与行为测试仍然必要；
行数本身不能证明架构质量。

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
   retry/progress/terminal ordering bridge. The 120-line pure
   `AsyncTransferSchedulerExecutionPolicy` validates retry attempt accounting,
   exact persistence rollback, monotonic stable-total progress, and the current
   running rate-expiry generation. Pure shutdown/suspension record and
   queue decisions live in `AsyncTransferSchedulerSessionEndPolicy`, while
   reversible pause/resume/cancel record and FIFO mutations live in the pure
   `AsyncTransferSchedulerControlPolicy`; its ordered effects cross persistence
   before the actor applies them. No pure policy owns tasks or I/O. The actor-confined
   `AsyncTransferSchedulerConsumerState` owns terminal outcomes, completion
   waiters, and snapshot observers without starting tasks or mutating jobs. Pure
   executor-unwind reconciliation lives in the 68-line
   `AsyncTransferSchedulerCompletionPolicy`; it mutates only the supplied record
   and returns an explicit pause/interruption/terminal resolution. The 743-line
   scheduler actor retains live task/record/queue, runtime effects, broadcast,
   and executor-unwind ownership. Its 73-line actor-confined persistence state owns
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
