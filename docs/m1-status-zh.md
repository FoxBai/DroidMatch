# M1 状态总结

最后更新：2026-07-15

## 当前实现状态

### ✅ 已完成功能

**Mac 端：**
- ADB 客户端（发现、转发、设备列表）
- Frame 编解码器（4 MiB 最大，长度前缀）
- 分帧 TCP 客户端/会话（Network.framework）
- 握手冒烟客户端（ClientHello/ServerHello）
- M1 冒烟客户端（完整控制平面测试）
- RPC 控制客户端（请求/响应处理）
- 面向产品层的异步 TCP/RPC actor（连接级 I/O 模式、唯一 multiplexed reader、request deadline 与取消安全 teardown）
- SwiftUI `DroidMatch` 产品 target：中英文设备总览、按 canonical path 本地化内置 provider 根、隐藏 opaque path 的可读导航标题、异步 ADB 发现、进程内 opaque 设备 ID、旧快照提示、生成式原生图标，以及已验证的本地 ad-hoc `.app` bundle。若 Hello-only 探测到 nonce-only 调试端点，产品会发布 `secureEndpointRequired` 并给出启用“安全 USB”的明确提示，不再误报为普通 transport failure。
- 产品会话生命周期：匿名动态 forward lease、按稳定身份选择 Keychain 记录、可见 SAS 审批、配对重连 proof、认证后的分页文件浏览，以及可导出 schema-v1 allowlist JSON（产品/macOS 版本与快照新鲜度）的隐私受限结构化诊断。可信设备元数据加载的忙状态现限制为 5 秒；Security.framework 仍阻塞时不会堆积重复请求，迟到的 Keychain 成功结果仍会自动恢复界面。本地测试已证明 heartbeat transport failure 与回显不一致会先拆除当前 gate/scheduler/client/forward，再由缓存的稳定事件清空全部 ready-only UI；显式断开不显示失败，配对信任继续保留。
- 跨端 envelope 校验（`frame_version` 与可选 payload CRC），其中 Mac 端负责 response/error request 关联，Android 在 handler 前拒绝并清理相关 transfer route
- 已强制握手 nonce 关联，并完成本地测试覆盖的首次配对/重连安全状态机；Slot C 已归档普通 App 的可见 SAS 配对、Keychain 重连、空闲保活和下载，以及 sandbox App 的配对、浏览、双向传输与强制终止后上传恢复
- 传输实现：
  - 单流下载（窗口化接收端控制，带 CRC32 验证）
  - 单流上传（窗口化，4 chunk / 2 MiB 在途，到 app-sandbox/MediaStore/SAF）
  - 单会话脚本化双下载流 smoke（按 stream ID 路由、公平处理 chunk、双流活跃时验证 heartbeat）
  - 单会话产品异步上传/下载混合 handle，并已在本地验证原子文件接收、四块上传窗口、heartbeat、取消与 refill 路由；同一成功契约现已由 `mixed-transfer-smoke` 暴露
  - 下载恢复（带源指纹验证）
  - 上传恢复（app-sandbox 和 SAF）
  - 传输取消和暂停
  - 会话内活跃 transfer ID 唯一、上传取消，以及以 ACK 为边界的下载暂停 offset
  - 基于 sidecar 的传输丢失重试（默认历史单次重试，可用 `--max-retry-attempts` 开启可配置恢复队列）
  - 原子下载写入器（部分 → 最终提交）
- CLI harness，命令包括：devices、forward、handshake-smoke、m1-smoke、dual-download-smoke、mixed-transfer-smoke、list-dir、download、upload 等
- 吞吐量测量（elapsed_ms、throughput_mib_per_sec）
- 可选的版本化传输队列 manifest：原子写入、稳定 job/FIFO identity、私有文件权限、sidecar 守门的 scheduler 重建，以及禁止自动重放的 `interrupted` 状态
- 不依赖 protobuf 的产品目录 domain 类型、分页/搜索/排序 `AsyncRpcControlClient` listing 与内嵌错误/row/token 校验；`DirectoryBrowserPresentationTypes` 负责不改变 remote identity 的 UI-only 文件名净化，`DirectoryBrowserPolicy` 纯处理 direct-child/mutation/media/error 决策，MainActor `DirectoryBrowserModel` 则唯一持有 client/Task/generation、原子 refresh、可重试 load-more、旧 generation 拒绝、跨页去重和脱敏 Published 状态；文件页另有 250ms 搜索 debounce、provider-side 名称/修改时间/大小升降序、已加载项目全选/清除与 stale selection 对账、稳定 path 多选/顺序批量删除、多文件下载防覆盖、Finder 多文件拖放上传、部分失败对账，列表/网格显示大小和本地化修改日期并提供能力受限的原生右键操作，MediaStore 图片/视频另有可见项缩略图和 512 px 点击预览，单响应限制 512 KiB、列表缓存限制 64 项
- 独立 `DroidMatchPresentation` library 与 MainActor `TransferQueueModel`：有序全量快照、显式幂等 start/stop/restart、非乐观 pause/resume/cancel/remove 回送、任务退场后的精确移除能力，以及仅含本地 basename 的展示状态
- 已认证的持久双向产品队列：可读文件使用原生保存面板，可写 app-sandbox/SAF/MediaStore 目录使用原生单文件选择器；私有 manifest 通过认证证明后从设备指纹派生的域分离路由实现设备隔离，文件名不再直接包含原始稳定指纹。M1 早期原始指纹文件名只通过原子无覆盖 rename 迁移；冲突、符号链接和非普通文件原样保留并 fail closed。每次尝试都通过会话 gate 创建新的配对 RPC client；app-sandbox/SAF 可恢复重试，MediaStore 保持 fresh-only；断开时暂停可恢复任务、阻断不安全重放，再释放 forward
- MainActor `DeviceDiscoveryModel`：原子 refresh、取消/generation 防护、脱敏失败状态，并确保 ADB serial 不进入 presentation

**Android 端：**
- 前台连接服务
- 一次性 ADB endpoint（仅 loopback，带超时、原子 stop/admission 与固定 4-session worker/socket 上限）
- 分帧 I/O（uint32_be 长度 + payload）
- 分配受限的传输热路径：每次 provider 读取直接填充一个精确 chunk buffer，
  只对最终短块 trim；4 字节 frame header 一次 bulk write；上传
  `TransferChunk` 直接从 envelope `ByteString` 解析；线格式与 4 chunk / 2 MiB
  窗口均未改变
- RPC 调度器（会话管理、请求路由）
- 协议处理器：
  - ClientHello/ServerHello
  - HeartbeatRequest
  - DeviceInfoRequest
  - ListDirRequest（roots、media、SAF、app-sandbox；provider-side `search_query` 在分页前过滤并绑定 opaque token）
  - CreateDirectoryRequest / RenamePathRequest / DeletePathRequest
  - ThumbnailRequest
  - OpenTransferRequest（下载和上传）
  - TransferChunk/TransferChunkAck
  - CancelTransferRequest
  - PauseTransferRequest
  - DiagnosticsRequest
- 文件提供者：
  - MediaStore（通过 content resolver 访问图片/视频）
  - MediaStore 图片相册（API 26–34 bucket 聚合、严格 opaque token、懒加载最新图片封面、相册内复用 canonical media path）
  - SAF（tree URI 权限、目录列表）
  - App sandbox（私有 files/droidmatch-sandbox）
- 提供者功能：
  - 下载：可定位 FD 或带偏移跳过的流
  - App sandbox 下载从已打开描述符 `fstat` 出元数据与 opaque source
    identity；同大小、同 mtime 的原子替换也会拒绝恢复，且不做全文件预哈希
  - 上传：隐藏 partial 通过同一 no-follow channel 校验、截断和续写；
    最终块会先 `force(true)` 同一描述符，再关闭并原子替换，任何同步或
    原子移动失败都不会返回最终成功 ACK
  - App sandbox 列表不发布符号链接；递归删除只 unlink 链接节点，
    不遍历或删除链接目标
  - 恢复：源指纹验证（下载）、部分偏移验证（上传）
  - ACK 丢失容忍（app-sandbox 上传截断/重放）
- 权限状态提供者
- 诊断报告器（带并发测试覆盖）
- Debug harness Activity（供真机脚本使用的独立 nonce-only 证据路径）
- 产品启动器入口（`DroidMatchActivity`）：提供经过单测的下一步就绪摘要，控制 paired-required endpoint、处理配对审批、列出/撤销不含密钥的已配对 Mac 元数据、处理通知权限并管理 SAF 授权；撤销信任会关闭活动 USB 会话，diagnostics harness 命名仅保留在 debug source
- 针对应用私有数据、配对、SAF、传输和诊断状态的显式禁备份/禁设备迁移规则
- 原创 adaptive vector launcher 标识，支持 Android 13+ monochrome 主题图标

**工具：**
- `tools/check-source-size.py`：全部手写生产、单元测试与 instrumentation 测试源码统一执行 800 行上限，已无存量例外
- `tools/push-main-with-gates.sh`：需显式确认的无 PR 所有者集成命令；只接受干净且可从实时 `origin/main` 快进的 HEAD，在任何远端 push 前先拒绝已知的维护者契约/测试数量漂移，再在唯一且可被保护层认可的临时 `push` ref 上验证同一 SHA，候选 CI 前后均核验 Phase A，并拒绝 main 前移或 run 事件/身份不匹配；它从不 force push，只清理自己创建的 ref，且仅在精确 `main push` CI 也通过、最终 Phase A 仍完整后返回成功。本地预检不能替代托管准入，离线套件覆盖预检拒绝、远端变更顺序和全部 fail-closed 边界
- `tools/run-m1-device-smoke.sh`：以 Swift release 配置构建并调用 Mac harness 的综合设备测试脚本；Git 状态不可读时 provenance 记为 unknown，并生成唯一严格的 `m1-device-smoke-v1` 记录，把已记录的 source/build/APK 身份、slot/API、检查依赖与结果标记、最终 offset、本次实传字节/速率、结果类别与清理意图绑定后再校验私有 staged 日志，最终以不跟随 symlink、不覆盖既有目标的方式发布。只有 clean、rebuilt、完整 revision 的运行属于 `device-evidence`；dirty/unknown/reused 的通过运行与失败运行都只算诊断。脚本含显式启用的 `--dual-download-check`，以及需要独立 fresh 上传目标的 `--mixed-transfer-check`；mixed-download 原子目标使用规范 `/private/tmp`，不经过 macOS 的 `/tmp` 符号链接
- Harness 下载目标的直接父目录为符号链接时，现在返回稳定且不包含路径的错误；CLI 帮助、活测试文档和人工拔线 runner 对直接子级临时下载统一使用规范 `/private/tmp`，活文档门禁会拒绝退回 macOS `/tmp` 的示例。原子 writer 仍拒绝跟随目标目录，也不会替调用者规范化输入。
- `tools/run-m1-throughput-gate.sh`：fail-closed Slot A `m1-adb-throughput-v2` profile；要求先通过 clean/rebuilt 的 `m1-device-smoke-v1` producer，并精确绑定完整 SHA、固定检查计划和重叠指标，再验证命令错误也会拒绝的 current-main provenance、API 26–29、fresh 双向精确 100MiB、raw ADB baseline、请求/实际协商 1MiB chunk、由本次实传字节与耗时反算一致的速率、双向 ≥20 MiB/s，以及固定受管零数据 hash 与下载/远端上传 SHA-256 在计时窗口外完全一致；随后还需通过隐私受限输出、清理验证、staged 单日志严格校验和原子 no-clobber fixture 发布。仓库没有 v1 fixture，因此只接受 v2
- `tools/run-product-usb-insertion-smoke.sh`：人工执行的 `m1-product-usb-insertion-v1` profile；包含起钟前再次确认不存在、先读单调时钟再发插入信号、精确发现卡片 AX 标识、运行中 release bundle provenance、物理动作确认和原子校验后发布
- `tools/check-product-usb-insertion-logs.sh`：严格校验产品插入 fixture 的结构、provenance、隐私、时延和计数
- `tools/m1-fault-proxy.py`：用于故障注入的本地帧代理
- `tools/check-m1-skeleton.sh`：CI 验证
- `tools/check-m1-run-logs.sh`：不回显命中内容的隐私拒绝，以及目录或 staged 单日志严格语义校验；新普通日志必须使用 `m1-device-smoke-v1`，89 份无 profile 历史 fixture 仅按 `legacy-v0.sha256` 冻结的精确路径与字节接受
- 自动结果记录到 `fixtures/m1-runs/`

**文档：**
- M0 收口（规格已最终确定）
- 协议文档（模式、运行时、路径）
- 设备矩阵要求
- 测试指南（退出标准的分步说明）
- 架构、安全模型、功能矩阵

### ⚠️ 部分实现

**配对与认证：**
- 当前 Hello 已强制 nonce 新鲜度/关联校验。
- v1 P-256 首次配对与两阶段 HMAC 重连方案已写入 `docs/pairing-auth-design.md`。
- Swift/Java canonical transcript、SHA-256、角色隔离 HMAC、常量时间校验和 HKDF 已通过同一固定向量。
- 两阶段重连 protobuf、Android challenge/proof 状态机、Mac async 双向 proof 校验、降级检测、未知 ID/坏 proof 统一失败和认证前 capability 拒绝已实现并通过测试。
- 首次配对 start/confirm/finalize protobuf、跨端 P-256/ECDH + 无偏 SAS + confirmation 原语、禁同步 Keychain store 和 Android Keystore AES-GCM wrapping store 已实现，并通过固定向量与注入 backend 测试。
- Android 稳定身份签名、默认关闭的 120 秒可见配对窗口、start/confirm/finalize dispatcher、Mac async client 和临时 Keychain 回滚已实现，并有 JVM 与 loopback 端到端测试。
- 首次配对、单 ID 重连和跨 ID 全局失败压力现已使用进程级指数退避，并覆盖随机 ID 轮换、空闲过期、内存上限和统一失败外形测试。
- 隔离的 AndroidX instrumentation runner 已在用户手动批准测试 APK 安装弹窗后于 Slot C MEIZU M20 通过：稳定 P-256 identity 与 AES wrapping key 均保持不可导出，签名、加密 record 重开及撤销 round trip 成功。这是需要人在场的证据，不代表可无人值守安装；runner 只移除测试包，并保留产品安装/数据边界。
- Mac 与 Android 均已提供不暴露密钥的信任管理。Mac 撤销会等待活动会话完全断开后再删除 Keychain 记录，Android 撤销会关闭活动 USB 会话。Slot C 普通 App 首次配对、已配对重连、sandbox 产品认证及需要人工批准安装的真实 Android Keystore 行为均已归档。

**传输功能：**
- 传输丢失重试：现已通过 `RecoveryPolicy` 实现可配置的多尝试恢复队列
  （指数退避、尝试上限、sidecar 守门）。
  - 默认 `--retry-on-transport-loss` 仍复刻历史的单次重试，向后兼容既有真机脚本。
  - `--max-retry-attempts N` 开启最多 N 次额外重连尝试。
  - `--retry-backoff-ms M` 覆盖基准退避（默认 500ms）。
  - 单元测试 + 端到端测试覆盖退避时序、尝试耗尽、本地故障注入服务器的多次断线恢复。
  - Core 已有可选磁盘队列 manifest 与恢复 factory；Mac App 只在认证证明完成后派生不透明 bookmark owner，其存储 key 仅 AppSupport SPI 可读且普通/调试/反射描述强制脱敏，并以 generation-bound single-flight 构建持久 scheduler：并发调用共享一次恢复，disconnect 会取消 build 并拆除已登记的 gate/scheduler，旧 build 不能清除新会话。随后在 execution latch 后恢复按设备隔离的 Application Support 队列，再对每个非终态本地 endpoint 校验该 owner 事务化持久的 App 自有 bookmark。Archive v2 阻止另一设备的空队列或同路径记录删除、满足当前 owner 的 scoped authority；v1 仅路径记录会原样保留在独立 legacy-unscoped fallback，本阶段不猜 owner、也不清理。损坏/不可读的恢复存储，或对这些已恢复目标为空、不完整、仅属于另一 owner 的 bookmark archive，会保持 `writeFailed` 且不重放；显式重试会先重载 bookmark，再在不执行的前提下重载 manifest、校验新的 owner 覆盖，最后解锁 scheduler。会话拆除会在保守暂停写盘后不可逆失效旧 scheduler，延迟 UI 动作不能恢复旧任务或覆盖新 manifest。
- 并发：稳定 M1 probe 与产品异步 core 都已有受限的双流路径
  - open response 和 chunk 按 request/stream ID 路由，并以公平顺序处理
  - Android 对同一会话的上传/下载合计强制最多 2 条活跃传输
  - Android 共享 provider 会跨会话拒绝第二个指向同一 canonical App Sandbox、SAF 或 MediaStore 目标的并发上传；不同目标仍互不阻塞，JVM 测试已覆盖 commit、abort、cancel、open 失败和会话 teardown 后的租约释放
  - 本地 TCP 端到端测试已证明 chunk 交错，并在首块 ACK 前验证 heartbeat 仍可响应
  - 重复 transfer ID 会先于流数量上限被拒绝，保证 transfer 级控制始终确定
  - 产品异步 router 已在唯一 reader 下本地交错验证 refill download、预检后的四块 upload window 与 heartbeat
  - 所有 multiplexed write 都经过同一个 FIFO admission gate；download ACK 与 upload chunk 取得 gate 后会重新读取 route 和 handle 共用的首个终态错误，因此排队写入不会越过 route teardown，恢复策略也会收到最初的可重试 transport 错误或 typed remote 错误，而非二次 inactive-route 失败
  - 协议取消会唤醒等待中的 upload window，但不关闭会话；后续 heartbeat 已证明会话可复用
  - 产品异步下载在私有串行文件队列写入，final ACK 前保留旧目标、取消时保留 partial，并在接收数据前拒绝变化的 resume offset
  - `AsyncDownloadCoordinator` 已读取 Core 共用 sidecar，通过注入的认证 client factory 重连，并以同一 transfer ID、实际 partial 偏移和已接受源指纹续传；本地 TCP 覆盖会断开首次会话并验证第二次原子完成
  - `AsyncUploadCoordinator` 已完成串行稳定源读取、四块/2MiB refill、逐 ACK sidecar 提交和 app-sandbox/SAF 重连；本地 TCP 覆盖证明从最后 ACK 重放，并在任务取消时保留 checkpoint
  - `AsyncTransferScheduler` 已提供 FIFO、两任务并发上限、buffering-newest queued/running/retrying/pausing/paused/interrupted/终态快照、跨重试单调的接收端确认 bytes/total、两秒时间加权近期吞吐、重试可见性、完成等待、取消和检查点暂停/继续。默认仍为进程内队列；`restoring(...)` 可选启用版本化原子 manifest，在 executor 启动前先落盘 queued→active，并可把所有启动路径持续锁在产品授权 readiness 之后。它只恢复 sidecar 匹配的 download/app-sandbox/SAF 任务，并把包括 MediaStore 在内的不安全 active 工作保留为禁止自动重放的 `interrupted`。排队 pause 是直接挂起；运行中检查点 pause 只关闭自己的 coordinator session，再以同一 job/transfer identity 入队。该本地策略不声称 Android wire upload pause。
  - 双流/混合流 probe 均可由脚本调用；下载与 provider-aware 上传 scheduler 已装配进认证后的视觉 target，具备按设备隔离持久化、App 自有 security-scoped bookmark 租约和按生命周期暂停。Slot C 已归档普通 App 配对/重连/下载，以及 sandbox App 配对/浏览/下载/上传；sandbox 上传恢复记录位于 App 自有的设备队列目录，不再写到只有读取授权的源文件旁。

**测试覆盖：**
- Slot D 设备（NIO N2301，API 34）：广泛覆盖
- Slot A（SHARP 704SH，API 26）：已归档满足槽位要求的 handshake/list 证据；两次功能完成的 100MiB 恢复探针使用旧 debug/Onone Mac harness，且早于当前传输优化，因此低于 20 MiB/s 的结果只是历史诊断，不是 current-tip gate 证据
- Slot C（MEIZU M20，API 34）：已有 handshake/list、app-sandbox 100MiB 下载/上传恢复吞吐、权限撤销、预期错误、MediaStore fresh-only 上传、sidecar/ACK 丢失恢复、可写 SAF 恢复，以及真机 source 修改/删除/同元数据替换拒绝覆盖；同大小、同完整 mtime 原子替换 probe 已在精确 main `0b4d858` 上归档通过并确认清理
- 未归类：Pixel 9 Pro Fold（API 37）已有 20/20 双设备 ADB 路由 smoke，但它不满足 Slot A 的 API 26-29 要求
- 握手稳定性：Slot A、Slot C 和 Slot D 都已有 20/20 运行
- 吞吐量：Slot D 和 Slot C 下载/上传已有归档通过的 100MiB 探针；Slot A 仍缺 current-tip release 配置下下载和上传均达到 20 MiB/s 的证据

### 暂缓的传输与发布工作（不是当前 ADB M1 阻塞项）

当前开放的 ADB M1 阻塞项只有两类：Slot A 当前候选版本的 release 吞吐证据，
以及 Slot A/C/D 需要人工参与的产品 USB 插入证据。对应的精确 runner 见下方
**高优先级（M1 阻塞项）**。

**实验传输（ADB M1 路径之后）：**
- AOA transport 实现及其独立的两设备晋级门禁

**已验证产品状态与剩余发布缺口：**
- Slot C 普通与 sandbox 认证 App 的配对/重连、浏览、双向传输、信任撤销和强退后上传恢复均已归档
- bundle 结构/ad-hoc 签名、内置 adb 发现、bookmark 生命周期、私有队列存储和断开处理已在本地验证；Developer ID 签名与公证属于明确暂缓的发布工作，不是 ADB M1 阻塞项
- 原生 Settings 与隐私受限的显式启用传输通知已实现；安全与破坏性操作保护不提供可关闭开关

**可选功能（v1.0 后）：**
- 屏幕镜像
- 通知镜像
- 剪贴板同步
- 文件夹订阅
- Wi-Fi 传输

## M1 退出标准进度

| 标准 | 状态 | 备注 |
|---|---|---|
| ADB 握手 ≥19/20 | ✅ Slot A/C/D 通过 | SHARP 704SH Slot A、MEIZU M20 Slot C 和 NIO N2301 Slot D 都已记录 20/20 次尝试；Pixel 9 Pro Fold API 37 也记录了未归类 20/20 smoke |
| USB 插入 ≤5s | ⚠️ fail-closed 产品/AX 证据路径已实现，仍需物理测量 | Mac App 前台活跃时每 1 秒执行非重入刷新；runner 要求唯一且已验证的 current-main release App、稳定发现卡片 AX 标识、起钟前不存在、明确 `INSERT NOW` 单调时钟边界和事后物理动作确认；目前归档证据仍为零 |
| 首次列表 ≤1s（预热） | ✅ Slot A/C/D 通过 | SHARP 704SH Slot A 测得 `elapsed_ms=165`；NIO N2301 Slot D 测得 `elapsed_ms=98`；MEIZU M20 Slot C 测得 `elapsed_ms=84`；命令外层 wall time 单独记录 |
| 100MB 下载 ≥20 MiB/s | ❌ 缺 Slot A current-tip 证据 | Slot C/D 有归档通过结果。SHARP 704SH 的 16.64/16.63 MiB/s 运行使用旧 debug/Onone harness，且早于当前传输优化，因此只是诊断，不能证明 current-tip 失败或通过 |
| 100MB 上传 ≥20 MiB/s | ❌ 缺 Slot A current-tip 证据 | Slot C/D 有归档通过结果。SHARP 704SH 的 15.20/15.70 MiB/s 运行使用同一过时执行路径，必须用 release 配置 runner 重跑 |
| 下载恢复 | ✅ Slot C 真机断线/修改/删除/同元数据替换通过 | 人工 10GiB 物理拔线保留了 3626762240 字节 durable partial，同一设备重连后恢复到精确最终大小。MEIZU M20 还以稳定 `invalidArgument` 拒绝 source 增加 1 字节和同大小、同完整 mtime 原子替换，并以稳定 `notFound` 拒绝已删除 source；替换 probe 已在精确 main `0b4d858` 上通过，provider 细节与原始文件系统身份均未输出。 |
| App-sandbox 上传恢复 | ✅ 已实现 | 带截断/重放容忍的部分 + 恢复 |
| Sidecar 传输重试 | ✅ Slot C/D 通过 | 故障注入以 `recovered=true` 通过；Slot C 和 Slot D 日志在使用非默认策略时记录了重试策略 |
| Fresh MediaStore 上传 | ✅ Slot C/D 通过 | Pictures/Movies 集合；MEIZU M20 已记录 fresh 上传和非零 offset 恢复拒绝 |
| Fresh SAF 上传 | ✅ Slot C 通过 | 用户选择的可写根；归档证据后已撤销临时授权并删除测试文件 |
| SAF 上传恢复 | ✅ 已实现 | Transfer-id 隐藏部分文档 |
| 权限拒绝映射 | ✅ Slot C/D 通过 | Media 列表撤销返回 `permissionRequired`。chunk 读取期间的 `SecurityException` 在 MediaStore/SAF 归一为 `permissionRequired`，app-sandbox 归一为 `internal`；但系统权限变化仍可能先拆除 endpoint，使 Mac 只能收到 transport loss。Slot C/D 都已归档这一合法结果，随后恢复授权。 |
| 诊断归因 | ✅ 已实现 | 服务/权限/传输状态 |
| 三设备覆盖 | ❌ 吞吐与插入 gate 未完成 | 所需 Slot A/C/D 设备均已有记录，但 Slot A 缺 current-tip release 配置下载/上传吞吐证据，且每台所需设备都仍缺人工产品 USB 插入 ≤5s 的归档证据 |
| AOA 可行性（2 设备） | ❌ 阻止 | 等待 ADB 路径完成 |

## 即时下一步

### 高优先级（M1 阻塞项）

1. **重新建立 SHARP 704SH（API 26）的 current-tip Slot A 吞吐证据：** 已归档的 16.63 MiB/s 下载和 15.70 MiB/s 上传满电复测使用旧 debug/Onone Mac harness，且早于当前传输优化。请经直连主机端口/线缆运行 `tools/run-m1-throughput-gate.sh --serial <serial> --expected-main-sha <40位SHA>`，让一个版本化 profile 同时记录 raw ADB baseline、fresh 双向精确 100MiB、实际协商 chunk、阈值、provenance、隐私边界与清理验证。第二台 API 26-29 设备只是在修改协议假设或阈值前建议执行的非阻塞交叉验证。不得用过时数值宣称失败或通过。

2. **在每台所需设备归档人工产品 USB 插入 ≤5s 证据：** 在 Slot A、Slot C 与 Slot D 上保持产品 App 前台运行，并为 `tools/run-product-usb-insertion-smoke.sh` 传入 `--device-slot`、clean `--expected-main-sha`、正在运行的 release `--app-bundle` 和新 `--result-log`。仅 ADB 可见不能替代产品证据；每个槽位都要有校验通过的真实插线 fixture 后才通过。

**证据维护说明（不是开放的 M1 阻塞项）：** Slot C 已归档下载和上传的人工物理 USB 拔线、同设备重连与续传，以及 source 修改、删除和同元数据替换拒绝。同元数据 probe 已在精确 main `0b4d858` 上以隐私受限输出通过并确认清理；这些专用场景仅在需要回归证据时重跑。

### 中优先级（M1 增强）

3. **推广已归档的多流真机证据：**
   - ✅ Slot C MEIZU M20 的 `--dual-download-check` 与
     `--mixed-transfer-check --mixed-upload-destination-path <fresh-target>`
     已在同一 async session 上通过，heartbeat 保持响应且证据已归档
   - ✅ 干净 commit `9ea1804` 在修复 runner 的 mixed-download `/tmp`
     符号链接路径后重跑 Slot C 组合回归：20/20 握手、双下载、同会话 10MiB
     下载/上传与 heartbeat、59 ms 预热列表、下载 resume/cancel/pause 和上传
     resume 均通过；runner 自有远端 final/partial、forward 与本地临时文件均已确认清理
   - 仅在需要区分设备特有行为时把相同 probe 扩展到 Slot A/D；Slot C
     多流证据已不再是开放 gate
   - ✅ 普通 ad-hoc App 的产品认证下载已用 Slot C 可清理数据归档
   - ✅ 已归档 sandbox bundle 下的产品认证 1MiB 下载与上传
   - ✅ sandbox App 强制终止后将上传恢复为暂停状态，重新取得 bookmark，并从 durable checkpoint 完成第 2 次尝试

4. **扩展 SAF 上传测试：**
   - 在多个 OEM 上测试可写 SAF 目录
   - ✅ smoke 清理现在会通过 fresh protocol `delete-path` session 删除
     直接 root 下的单文件 SAF 目标；进程内 document token 与递归目录清理仍需显式/手动处理
   - ✅ 本地 writer 测试已验证：不可恢复上传非最终关闭会删除未完成文档，
     可恢复上传会保留隐藏 partial，完成的可恢复上传会重命名且不会删除成品
   - 在多个 OEM 的可写 SAF provider 上重复上述清理/保留场景
   - 记录厂商的 SAF 提供者特性

5. **在签名 sandbox App 中演练持久队列恢复（M1 后证据）：**
   - 归档同一认证设备下可恢复排队传输的重启流程
   - 归档 stale bookmark 刷新与配平的 security-scope release
   - 在可清理状态上确认 `interrupted` 与持久化健康 UI

### 低优先级（M1 后）

6. **大目录压力测试：**
   - ✅ 本地正确性基线：真实 app-sandbox catalog 将 1005 个文件分页为
     1000 + 5，产品模型连续读取三页共 1205 项后保持顺序、唯一性和正确终止
   - 1000+ 条目的 MediaStore 列表
   - 产品 pager 连续读取多个 1000 条目页面的性能
   - ✅ Slot C app-sandbox provider 端到端分页：可清理的 1005 条目目录在
     833 ms 内返回 1000 + 5 行，只归档聚合证据并确认清理
   - ✅ 本地 Java 内存形态：App Sandbox 流式遍历目录，App Sandbox/SAF
     都最多保留排序前 `offset + pageSize` 个候选；MediaStore 将
     limit/offset/sort 下推给 `ContentResolver`
   - ✅ Slot C 进程级诊断：分页 1,005 个 App Sandbox 条目并采样聚合 PSS，
     baseline 为 31,664 KiB、观测峰值为 38,313 KiB（增量 6,649 KiB）；
     这是设备证据，不是 heap allocation 证明或可跨设备复用的内存上限

7. **AOA 路径探索：**
   - 在 ADB 在 3 个设备上通过 M1 后
   - 需要至少 2 个支持 AOA 的设备
   - 吞吐量目标：≥30 MB/s

## 已知限制

- **已有认证持久双向传输产品路径，但还不是完整管理器：** 本地化 SwiftUI target 已具备 serial 脱敏发现、动态 forward、SAS/Keychain 认证、文件浏览、诊断、原生面板、设备隔离队列和 App 自有 bookmark 租约。带 sandbox entitlement 的 bundle 已在 MEIZU M20 上归档配对、浏览、1MiB 双向传输，以及强制终止后恢复 4GiB 上传。压缩本地 DMG、Applications 快捷方式、SHA-256、只读挂载及挂载后 App 复核已实现；Developer ID 签名与公证尚未验证。
- **文件规模之外仍有结构性债务：** 全部手写生产与测试文件均满足默认 800 行预算，所有产品/CLI 网络路径均使用 async transport；文件浏览工具栏、传输持久化映射、transfer frame、scheduler 测试支持及本地 framed-server 的状态/读取器/响应值已有明确边界，贡献与 PR 交接证据由 CI 强制检查，但单一 GitHub owner 的发布权限仍然集中；见[结构性债务基线](technical-debt.md)
- **多流支持范围有限：** 普通 CLI download/upload 仍为单传输；`dual-download-smoke` 与 `mixed-transfer-smoke` 是显式 probe。混合方向及预检后的 4 chunk / 2 MiB upload window 已有本地 TCP、真机脚本入口和 Slot C 归档真机结果；Slot A/D 仅在需要区分设备特性时再扩展。
- **重试默认单次：** `--retry-on-transport-loss` 默认仍只重试一次以保持向后兼容；需显式传 `--max-retry-attempts N` 才启用多尝试恢复队列
- **可恢复 SAF partial 生命周期：** 不可恢复上传非最终关闭会删除未完成文档；
  带 transfer ID 的上传会有意保留隐藏 partial。smoke runner 现在会通过 protocol
  delete mutation 清理直接 root 单文件 SAF 目标；放弃的可恢复 partial 与进程内
  document-token 目标仍需显式清理。
- **MediaStore fresh-only：** 不支持上传恢复（返回 unsupportedCapability）
- **相册首次索引成本：** 为保持 API 26–34 一致语义，首次相册列表会流式扫描 MediaStore bucket 列，但内存只随相册数增长；有界 LRU 会避免每个相册封面重复扫描，服务重启后的旧 token 解析可能再触发一次扫描。
- **仅 ADB loopback：** Android endpoint 拒绝非 127.0.0.1 客户端
- **需要 debug harness Activity：** 某些 OEM 设备在没有前台 Activity 的情况下冻结服务 accept() 线程
- **Android 15 后台服务额度：** ADB loopback endpoint 使用 `dataSync` 前台服务类型，每 24 小时最多在后台运行 6 小时。超时后会关闭 endpoint 并停止 non-sticky service；未来 AOA 路径只有在取得真实 USB accessory grant 后才能使用 `connectedDevice`。

## 测试结果摘要

截至 2026-07-15，`fixtures/m1-runs/` 包含：
- 89 个测试结果日志
- SHARP 704SH（Slot A，API 26）的 handshake/list 和历史 100MiB 吞吐诊断、NIO N2301（Slot D，API 34）的较完整矩阵覆盖、MEIZU M20（Slot C，API 34）的 handshake/list、app-sandbox 吞吐/恢复、权限、预期错误、MediaStore 和恢复证据，以及 Pixel 9 Pro Fold（API 37）的未归类双设备 ADB 路由 smoke
- 覆盖：app-sandbox 上传（fresh/resume/100MB）、app-sandbox 下载恢复/100MB、真机恢复前 app-sandbox source 修改、删除和同元数据原子替换、MediaStore 上传、Media 列表和下载期间权限撤销、预期错误边界、cancel、pause、Slot D 握手稳定性（20/20）、Slot C 握手稳定性（20/20）、Slot D/Slot C 吞吐断言、ADB baseline 下载诊断、可配置恢复策略故障 smoke，以及 app-sandbox ACK 丢失重放
- 通过：Slot D 窗口化下载用 1MiB chunk 测得 48.95 MiB/s，同文件 ADB baseline 为 75.70 MiB/s
- 通过：Slot D 窗口化上传用 1MiB chunk 测得 33.51 MiB/s，通过 20 MiB/s gate
- 通过：Slot D 预热 media-images 列表测得 harness `elapsed_ms=98`，通过 1000 ms gate
- 通过：Slot D Media 权限撤销后 `dm://media-images/` 返回 `permissionRequired`，随后恢复原授权
- 通过：Slot D 在 `dm://media-images/media/1000001148` 下载期间撤销 Media 权限后观测到 `transport_lost_after_revoke`，随后恢复原授权
- 通过：MEIZU M20 Slot C 在 20/20 次 `m1-smoke` 后，预热 media-images 列表测得 harness `elapsed_ms=84`，通过 1000 ms gate
- 通过：MEIZU M20 Slot C app-sandbox 100MiB 下载恢复测得 35.52 MiB/s，ADB baseline 为 36.90 MiB/s
- 通过：MEIZU M20 Slot C app-sandbox 100MiB 上传恢复在 Mac harness send-limit 修复后测得 20.22 MiB/s
- 通过：MEIZU M20 Slot C 在 ACK 驱动持续补帧后，不可压缩 100MiB app-sandbox 上传分别测得 256KiB chunk 32.73 MiB/s、512KiB chunk 35.29 MiB/s、1MiB chunk 22.77 MiB/s；恢复、传输中断重试和 ACK 丢失重放也分别以 36.20、34.33、35.04 MiB/s 通过
- 通过：MEIZU M20 Slot C 可写 SAF 根目录的 10MiB 不可压缩上传恢复测得 27.36 MiB/s；传输中断首次暴露 provider partial 超前于 Mac 持久 ACK，加入 seekable partial 截断后以 `recovered=true`、27.14 MiB/s 通过，随后撤销授权并删除专用测试目录
- 通过：MEIZU M20 Slot C Media 权限撤销后 `dm://media-images/` 返回 `permissionRequired`，随后恢复原授权
- 通过：MEIZU M20 Slot C 预期错误边界：缺失 SAF root 和缺失 app-sandbox 下载源均返回 `notFound`
- 通过：MEIZU M20 Slot C MediaStore fresh 上传成功，且非零 offset 上传恢复返回 `unsupportedCapability`
- 通过：send-admission 与权限读取修复后，MEIZU M20 Slot C 复测 10MiB MediaStore fresh 上传，以 25.38 MiB/s 完成，随后另用一项已准备的 10MiB MediaStore 测试项执行下载中撤权复测。复测得到 `transport_lost_after_revoke` 并恢复原授权；后续归档的清理核验确认精确的一次性上传文件名对应 row 为零，默认本地 download/partial/sidecar 产物也为零。已归档的修复前运行仍保留为失败证据，因为二次 inactive-route 错误遮蔽了原始失败。
- 通过：MEIZU M20 Slot C app-sandbox 上传 ACK 丢失重放以 `recovered=true` 恢复
- 通过：MEIZU M20 Slot C app-sandbox 100MiB 下载故障重试以 `recovered=true` 恢复
- 通过：较早的 MEIZU M20 Slot C 在 `dm://media-images/media/1000000054` 下载期间撤销 Media 权限后仍完成并恢复原授权；上述后续 10MiB 回归覆盖了传输中失败路径并观测到 transport loss
- 通过：MEIZU M20 Slot C 在 262144 字节部分下载后，将脚本创建的 1MiB app-sandbox source 修改为 1048577 字节；恢复正确返回稳定 `invalidArgument`（指纹细节已脱敏），设备和 Mac 临时文件均已清理
- 通过：MEIZU M20 Slot C 在精确 main `0b4d858` 上完成同元数据替换；262144 字节部分下载后，以同目录原子 rename 替换脚本创建的 1MiB app-sandbox source，保持大小/完整 mtime 相等并改变 inode/内容，恢复稳定返回 `invalidArgument`，原始元数据未输出，设备和 Mac 临时文件均已清理。
- 通过：MEIZU M20 Slot C 在 262144 字节部分下载后删除脚本创建的 1MiB app-sandbox source；恢复正确返回稳定 `notFound`（provider 细节已脱敏），设备和 Mac 临时文件均已清理
- 通过：MEIZU M20 Slot C 在 commit `a897e70` 上完成 source 删除、cancel、pause 与 app-sandbox ACK 丢失恢复组合 smoke；删除返回稳定 `notFound`，后续 cancel/pause 前重新创建临时 source，20/20 握手和双下载通过，10MiB ACK 丢失上传以 27.03 MiB/s 恢复
- 通过：MEIZU M20 Slot C 的干净 commit `9ea1804` 在不放宽 `O_NOFOLLOW` 的前提下暴露并修复 device runner 的 mixed-download `/tmp` 符号链接回归；复跑完成 20/20 握手、双下载、同会话 10MiB 混合下载/上传与响应中 heartbeat、59 ms 预热列表、下载 resume/cancel/pause 和上传 resume。下载/上传恢复分别为 30.72/20.27 MiB/s，runner 自有远端 final/partial、ADB forward、Mac 临时文件与产品入口恢复均已确认。
- 通过：MEIZU M20 Slot C 在当时精确 main commit `aaf332a8` 上完成隔离 Android Keystore instrumentation；不可导出的 identity/signing 与 AES wrapping/reopen/revoke 两项测试均通过（`OK (2 tests)`），测试包已移除，产品包和数据边界保持不变
- 通过：SHARP 704SH Slot A 握手稳定性 20/20 通过，预热 `dm://media-images/` 列表测得 `elapsed_ms=165`
- 仅历史诊断：SHARP 704SH Slot A app-sandbox 100MiB 下载恢复以 16.64 和 16.63 MiB/s 完成，原始 ADB baseline 分别为 7.19 和 11.21 MiB/s
- 仅历史诊断：SHARP 704SH Slot A app-sandbox 100MiB 上传恢复以 15.20 和 15.70 MiB/s 完成
- 这些 Slot A 运行使用旧 debug/Onone Mac harness，且早于当前传输优化；它们既不能证明 current-tip 通过，也不能证明失败，必须用 release 配置 runner 重跑
- 通过：Pixel 9 Pro Fold API 37 未归类 smoke 在两台 ADB 设备同时连接时通过显式 serial 路由完成 20/20 次尝试
- 单测覆盖异常路径：stale 下载恢复 source fingerprint、invalid page token、oversized envelope、flagged envelope-payload CRC mismatch、bad transfer-chunk CRC32、终止性畸形 chunk/ACK/provider/capability 清理、有界迟到窗口吸收、方向错配与交叉 request/stream ID
- 通过：MEIZU M20 Slot C 在 2GiB app-sandbox 上传至 768081920 字节持久 ACK 后物理拔线；重新插入、授权、重启 Activity 并重建动态 ADB forward 后，从同一 sidecar 恢复剩余 1379401728 字节，最终设备文件为 2147483648 字节
- 通过：Slot C 普通 ad-hoc 产品 App 可见 SAS 配对、新鲜认证、Keychain 重连、跨越旧 30 秒边界的四次 heartbeat、认证 app-sandbox 列表、原生队列 1MiB 下载与清理
- 通过：Slot C sandbox 产品 App 完成可见 SAS 认证、app-sandbox listing、目录授权的 1MiB 下载、App 自有恢复记录的 1MiB 上传、双向 hash 对账与清理
- 通过：当前普通产品 App 通过 paired-required 安全 USB 与 MEIZU M20 完成仅本地等值判定的 SAS 配对，两端持久化信任；断开后不再显示 SAS 即可认证重连，重连后实时 root 浏览、健康空队列和隐私受限的 paired-proof 诊断均可用；最终释放全部 ADB forward 并关闭安全 USB，同时保留配对信任
- 通过：Slot C sandbox App 在 4GiB 上传期间被 `SIGKILL` 后恢复为显式暂停任务，重新取得源文件 bookmark，从 598999040 字节开始第 2 次尝试，最终 hash 一致并清理恢复状态
- 通过：MEIZU M20 Slot C 在 10GiB app-sandbox 下载持久 partial 达到 3626762240 字节后物理断线；同一 serial 以新 transport identity 重连，并以 28.35 MiB/s 恢复剩余 7110656000 字节至精确最终大小
- 缺失：Slot A 经直连物理 USB 路径得到的 current-tip release 配置下载/上传 ≥20 MiB/s 证据；第二台 API 26-29 设备仍是建议执行的非阻塞交叉验证
- 缺失：每台所需 Slot A/C/D 设备的人工产品 USB 插入 ≤5s 证据

`fixtures/product-usb-insertion/` 包含：
- 0 个产品 USB 插入证据日志

## 参考文档

- [M1 测试指南](m1-testing-guide-zh.md)：分步测试说明
- [M1 设备矩阵](m1-device-matrix.md)：所需设备和通过标准
- [M0 收口](m0-closeout.md)：规格决策
- [协议运行时](protocol-runtime.md)：并发限制和反压
- [协议](protocol.md)：消息模式和语义
- [路径模型](path-model.md)：逻辑路径抽象
