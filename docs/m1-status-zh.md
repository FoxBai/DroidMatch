# M1 状态总结

最后更新：2026-07-19

## 当前实现状态

### ✅ 已完成功能

**Mac 端：**
- ADB 客户端（发现、转发、设备列表）
- Frame 编解码器（4 MiB 最大，长度前缀）
- 分帧 TCP 客户端/会话（Network.framework）
- 握手冒烟客户端（ClientHello/ServerHello）
- M1 冒烟客户端（完整控制平面测试）
- RPC 控制客户端（请求/响应处理）
- 面向产品层的异步 TCP/RPC actor（连接级 I/O 模式、唯一 multiplexed reader、request deadline 与按 send admission 分类的取消语义：已准入 mutation/传输控制取消为会话终止，已准入只读 heartbeat/device-info/listing/diagnostics/thumbnail 取消则在原 deadline 内保留、校验并排空待响应）
- SwiftUI `DroidMatch` 产品 target：中英文设备总览、独立“媒体”侧栏、按 canonical path 本地化内置 provider 根、隐藏 opaque path 的可读导航标题、异步 ADB 发现、进程内 opaque 设备 ID、旧快照提示、生成式原生图标，以及已验证的本地 ad-hoc `.app` bundle。Files 隐藏 Images、Image Albums、Videos 三个 root；Media 是唯一的产品媒体入口，其中图片、相册和视频各自保留浏览状态，同时复用认证后的分页、搜索、排序、网格、预览和传输界面。若 Hello-only 探测到 nonce-only 调试端点，产品会发布 `secureEndpointRequired` 并给出启用“安全 USB”的明确提示，不再误报为普通 transport failure。
- 产品会话生命周期：匿名动态 forward lease、按稳定身份选择 Keychain 记录、可见 SAS 审批、配对重连 proof、认证后的分页文件与媒体浏览，以及可导出 schema-v1 allowlist JSON（产品/macOS 版本与快照新鲜度）的隐私受限结构化诊断。媒体 root 不进入 Files，因此 Media 界面的实时 capability 检查覆盖每一个产品媒体入口。媒体 root metadata 来自 Android 实时 capability；已标记不可读的 root 不会被目录探测，显式权限重新检查会先清空并重列所有已加载媒体 query，即使 Android 14 仅选媒体范围变化后 root 仍保持可读也不会保留旧名称。child 权限失败只阻塞其稳定分类，不形成自动 catalog/list 循环。独立写能力仍可保留直接上传，Mac/Android 都会校验精确文件名类型，界面也会在操作前说明 MediaStore fresh-only 边界。可信设备展示元数据使用禁止交互的 `LAContext`，忙状态限制为 5 秒；Security.framework 仍阻塞时不会堆积重复请求，迟到的 Keychain 成功结果仍会自动恢复界面。不可用界面会区分“系统请求仍未返回”和“已经可以重试”：等待期间说明这项被动检查不会弹出认证窗口并提示重开 DroidMatch，旧请求真正退场后才显示“重试”。本地测试已证明 heartbeat transport failure 与回显不一致会先拆除当前 gate/scheduler/client/forward，再由缓存的稳定事件清空全部 ready-only UI；显式断开不显示失败，配对信任继续保留。
- 外部名称展示加固现由 Mac 单一有界投影覆盖 ADB 型号/产品、配对、可信设备、ready 会话、诊断和远端条目；Android 等价投影同时覆盖对端名称及 SAF 授权行/确认。Mac 默认最多 120 个 Unicode 标量（远端条目 240），Android 最多 120 个 code point，两端都为真实可见截断在上限内保留省略号。动作身份仍是匿名设备 ID、配对记录、logical path 或稳定 SAF root。Mac Published 配对确认只含安全 Android 名称与六位 SAS，Core 身份指纹不进入 Presentation 状态。
- Mac 发现现会给设备卡补充仅用于展示的真实商品名，同时把原始 model/product 保留为次行技术信息。独立、有界、来源可审计的本地别名表会按 Mac 首选语言执行完整标签→地区→文字→基础语言回退，要求精确设备身份，拒绝重复/不安全记录，并且只持久化 canonical name。SHARP 704SH 可离线解析为夏普唯一已审核的日文「シンプルスマホ4」；中英文不会得到编造的翻译，而是安全保留该原名。其他缓存未命中项通过无 Cookie、拒绝重定向的临时会话流式请求唯一固定的 Google Play 完整公开目录。独立 catalog-loader actor 执行 8 MiB、UTF-16LE、表头、行数和字段长度上限并构建有界索引，resolver actor 最多保留 64 个待查参数。匹配/缓存身份使用完整的 512-scalar 有界参数而不是 120-scalar UI 投影，原始商品名唯一后才进入安全投影。Core 不发送 serial 或逐设备搜索词，本地最多用参数元组 SHA-256 键保存 512 个安全 canonical name；任何失败都回退到既有安全技术名称。七项解析器/发现直接回归使当前 Swift 库存增至 472。本项只有本地自动化证据，不新增 current-tip 704SH 真机通过声明。
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
  - 原子下载写入器：final、partial、sidecar、sidecar 的 `.pending`/`.removing`、固定 commit marker 和 fixed replaced entry 组成同一冲突命名空间；产品执行期同时持有按父目录 inode/卷大小写语义键控的进程内 registry、按固定顺序取得的跨进程 advisory 锁、security scope 与目录 FD。已固定父目录内的私有 `0700` `.droidmatch-download-locks`、`0600` `.droidmatch-download-lock-root` identity anchor 和域分离 SHA-256 命名的持久空锁文件会校验 owner、权限、类型、链接数与 inode；每个此前未见目标最多新增七个零字节 inode。名称不直接包含目标文件名，但哈希只是匿名化元数据而非加密。partial 必须是单链接普通文件并持有非阻塞独占 `flock` 到发布完成；fresh 先锁定且不截断，安全移除旧 sidecar，再在同一 FD 上 reset，全部成功后才连接。提交先创建并同步 `0600` 固定 marker，再走 `RENAME_EXCL` 或经验证的 `RENAME_SWAP`；旧目标保留在固定 replaced entry，直到 sidecar 删除成功。finalize 前失败/取消会先恢复旧目标与 candidate partial，在 marker 仍存在时重新持久化 sidecar，只有 checkpoint 恢复成功才退役 marker；恢复失败会保留 marker 并在重启时转为 `interrupted`。无法证明才返回不自动重试的 `commitUncertain`。目录 `fsync` 是必需步骤，但不宣称完整断电耐久性或抵抗主动忽略 advisory 锁的同 UID 恶意进程。
  - 上传 v2 checkpoint 将大小、纳秒 mtime、纳秒 ctime、filesystem number 与 inode 绑定到本次尝试唯一且持续持有的 `O_NOFOLLOW` 源描述符；每次读取前后都会同时复核 path 与 descriptor。restore 尚未持有 bookmark lease 时只校验 v2 结构/路径，lease 建立后 coordinator 会在 client factory 前精确 snapshot 并拒绝 stale source。同大小、同毫秒 mtime 的替换会被拒绝，旧版非零 v1 checkpoint 会在重连前 fail closed。
  - 可恢复上传新增严格双重 write-ahead：首次远端 open 前，v2 sidecar 与 schema-v2
    队列都会持久化精确 destination/transfer/expected-size 清理身份。永久取消、终态历史
    移除和 shutdown 都保留可重试 cleanup；新的配对认证 client 必须同时具有
    `FILE_WRITE`/`RESUMABLE_TRANSFER`，且只删除精确 App Sandbox/SAF 私有 partial。
    缺失视为幂等成功，最终目标永不进入删除路径；成功后才 settle/移除任务并释放
    bookmark。恢复后的 cleanup 优先于普通队列任务，pause/会话挂起仍保留恢复状态。
    本地 Swift/JVM/wire 测试覆盖 write-ahead 失败、schema-v1 兼容、取消/移除/shutdown
    恢复、认证能力、目标排他、精确路由、幂等及 final 保留；不新增真机证据。
- CLI harness，命令包括：devices、forward、handshake-smoke、m1-smoke、dual-download-smoke、mixed-transfer-smoke、list-dir、download、upload 等
- 吞吐量测量（elapsed_ms、throughput_mib_per_sec）
- 可选的版本化传输队列 manifest：原子写入、稳定 job/FIFO identity、私有文件权限、sidecar 守门的 scheduler 重建，以及禁止自动重放的 `interrupted` 状态。不可信恢复输入限制为最多 10,000 个 job、10,000 次配置重试、一天退避和累计 1,000,000 次 attempt；queued 与普通 paused 必须为完整重试策略预留空间，可恢复 pause 只能从已消费 attempt 或确已发布的下一次 retry 继续，active 无余量则转 interrupted。运行时 retry/resume/terminal 也使用同一 checked 上限；retry 若无法跨越 manifest 写盘边界，会取消 executor 并关闭持久执行。只有结构/路径有效、total 已知无冲突且 `0 <= offset < total` 的 checkpoint 恢复 paused；`offset == total`、`0 / 0`、unknown/conflicting total 等均恢复 interrupted。损坏 manifest 修复后的产品重试会在 executor 仍被 held 时重新加载 bookmark store，取得全部 checkpoint security scope 与 download directory capability，规范化整个队列并验证 readiness 后才激活；任何一步失败都保持 reload-required，可再次重试。会话挂起也会等待不安全 executor 真正退场后才 settle：普通结果保持 interrupted，只有已越过本地回滚边界的 download 才能改为 completed。sidecar 与私有 queue/bookmark 使用固定 `.<name>.pending/.removing`、完整 stat、parent 重绑定复核和强制文件/目录 `fsync`。每个已使用的固定 parent 永久保留一个零字节 `0600` `.droidmatch-private-atomic-lock`；no-follow 打开及独占 `flock` 前后的 owner/type/link/mode 与目录名/FD inode 复核，会把协作进程和同进程独立 FD 的 read/save/remove 串行到同一 inode。不安全锁节点与崩溃 marker 均 fail closed；失败要么证明回滚，要么以 `commitUncertain` 保留 recovery node。同 UID 恶意进程仍可绕过 advisory lock 并竞态最终 stat→unlink 窄窗口，这不等于断电耐久性。
- 不依赖 protobuf 的产品目录 domain 类型、分页/搜索/排序 `AsyncRpcControlClient` listing 与内嵌错误/row/token 校验；可选 provider MIME 会规范为最长 127 字节的受限小写 ASCII 值，畸形 metadata 只降级为 `nil`，不会改变 row identity、capability 或授权。`DirectoryBrowserPresentationTypes` 负责不改变 remote identity 的 UI-only 文件名净化及独立浏览/上传投影，`DirectoryBrowserPolicy` 纯处理 direct-child/mutation/media/error 决策，MainActor `DirectoryBrowserModel` 则唯一持有 client/Task/generation、原子 refresh、可重试 load-more、旧 generation 拒绝、跨页去重和脱敏 Published 状态。纯 `DirectoryBrowserThumbnailState` 只持有缩略图 generation/FIFO/active-key/失败/缓存 transition；旧 generation 已准入请求在排空前仍占四项上限，但不能发布，缓存统一限制为 64 项和 8 MiB，且该纯值不持有 client、Task、权限判断或 Published 值。导航只取消旧 listing 并清空旧 generation 尚未准入的行缩略图，不取消已准入 mutation；同 path 完成刷新当前搜索/排序 query，其他 path 则丢弃旧结果/错误。浏览器隐藏时清理排队派生任务、预览和缓存，但保留 listing/query/导航。512 px 预览在缩略图队列外，可作为第五个 control request。listing 分页与预览/缩略图有独立有效性，load-more 不会使当前预览永久停在 loading。不可读 root 不再发起 list，但独立可写的 root 仍保留直接上传。文件页另有 250ms 搜索 debounce、provider-side 名称/修改时间/大小升降序、已加载项目全选/清除与 stale selection 对账、稳定 path 多选/顺序批量删除、多文件下载防覆盖，以及共用同一可测准入策略的原生面板/Finder 多文件上传：按顺序接受 1–100 个非符号链接普通文件，拒绝规范化后重名和目标/媒体类型不匹配；部分入队失败会保留并明确提示已接受任务。列表/网格显示大小和本地化修改日期并提供能力受限的原生右键操作，MediaStore 图片/视频单响应限制 512 KiB
- 多选下载会在任何入队前拒绝规范化重名和已存在本地目标。后续任务独立持久化；全部或部分未被接受时使用不同的固定指引，已接受任务仍留在“传输”中，只有未接受文件保持选中以安全重试，不会误报为整批回滚。
- 独立 `DroidMatchPresentation` library 与 MainActor `TransferQueueModel`：有序全量快照、显式幂等 start/stop/restart、非乐观 pause/resume/cancel/remove 回送、同 job 重复动作抑制、任务退场后的精确移除能力，以及仅含安全本地 basename 的展示状态。本地 basename 在进入 SwiftUI 或 opt-in 系统通知前统一经 `ProductDisplayText` 去伪装并限制长度；未使用的完整远端路径不再进入 Published item，动作仍只按 UUID。一个 model-wide 单飞闩锁会在数据源产生副作用前，串行文件/媒体页的单项及批量下载/上传准入；已准入任务仍由 scheduler 并发执行。App 在同一 busy 生命周期内禁用搜索、选择、行/右键动作、导航和媒体分类切换，批量完成只按已接受请求索引从当前选择中移除对应项。持久化不健康或正在恢复时，新提交与稳定顺序批量清理彼此互斥；全部文件/媒体传输入口会在原生面板打开前禁用并就地显示恢复告警，浏览和远端文件操作仍保持可用。批量清理只准入已完全收尾的成功行，保留失败、取消、interrupted、pending 与仍在退场的任务，部分移除显示精确计数。重试/失败/中断指引只来自精确 Core 标签解析出的粗粒度类型；未知或附加文本会被拒绝，原始 failure description 不进入 Presentation。
- 产品传输入口以及传输页的暂停、继续、取消、移除和批量清理会等待首次权威持久化状态读回，初始 `.disabled` 占位值不会被误当作已验证健康。未知或恢复中的存储显示为等待态而非绿色健康态，存储失效会阻止行级 mutation，竞态中的底层拒绝只显示固定本地化提示，不暴露路径或原始错误；浏览和远端文件操作仍可使用。
- 已认证的持久双向产品队列：可读文件使用原生保存面板，可写 app-sandbox/SAF/MediaStore 目录使用最多 100 个文件的原生选择器，每项独立持久化且不会把部分成功伪装成整批回滚；私有 manifest 通过认证证明后从设备指纹派生的域分离路由实现设备隔离，文件名不再直接包含原始稳定指纹。M1 早期原始指纹文件名只通过原子无覆盖 rename 迁移；冲突、符号链接和非普通文件原样保留并 fail closed。每次尝试都通过会话 gate 创建新的配对 RPC client；app-sandbox/SAF 可恢复重试，MediaStore 保持 fresh-only；断开时暂停可恢复任务、阻断不安全重放，再释放 forward
- MainActor `DeviceDiscoveryModel`：原子 refresh、取消/generation 防护、脱敏失败状态，并确保 ADB serial 不进入 presentation

**Android 端：**
- 前台连接服务
- 一次性 ADB endpoint（仅 loopback，带超时、原子 stop/admission 与固定 4-session worker/socket 上限）；READY 前任何拒绝帧都会清零并关闭 setup session，周期性坏帧不能刷新首帧窗口或长期占用该上限
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
  - ListDirRequest（roots、media、SAF、app-sandbox；provider-side `search_query` 在分页前过滤并绑定 opaque token；精确请求默认 200、最多 1,000 条，token 不能越过每个精确查询 10,000 条的可检索范围；若最后一个可接收窗口后仍有条目，则返回仅含 `unsupportedCapability` 的错误而不是空 token 静默截断；App Sandbox/SAF 检查到 25,000 个 provider row 后也以同一稳定有界能力错误停止）
  - CreateDirectoryRequest / RenamePathRequest / DeletePathRequest
  - SAF rename token 会保留列出时的 parent provenance；parent 缺失或跨目录请求在平台 name-only rename 前拒绝，同 parent 与 root 直系子项重命名保持支持
  - ThumbnailRequest
  - OpenTransferRequest（下载和上传）
  - TransferChunk/TransferChunkAck
  - CancelTransferRequest
  - PauseTransferRequest
  - DiagnosticsRequest
- 文件提供者：
  - MediaStore（通过 content resolver 访问图片/视频）
  - MediaStore 图片相册（API 26+ bucket 聚合、严格 opaque token、懒加载最新图片封面、相册内复用 canonical media path；相册真机证据目前最高到 API 34）
  - SAF（tree URI 权限、目录列表）
  - App sandbox（私有 files/droidmatch-sandbox）
- 提供者功能：
  - 下载：可定位 FD 或带偏移跳过的流
  - App sandbox 下载从已打开描述符 `fstat` 出元数据与 opaque source
    identity；同大小、同 mtime 的原子替换也会拒绝恢复，且不做全文件预哈希
  - 上传：transfer-scoped 私有 staging 位于公开 app-sandbox root 之外的
    sibling 目录，不透明名称同时绑定 destination、transfer 与 expected size。
    sibling staging 节点必须在 `NOFOLLOW` 校验下是真实目录；普通文件或
    符号链接会原样保留并 fail closed。fresh 清理遇到匹配的异常目录或符号链接
    partial 也会保留并拒绝，不会将其删除。resume partial 通过同一 no-follow channel
    校验、截断和续写；最终块会先 `force(true)` 同一描述符，再关闭并原子替换，
    任何同步失败或不支持的原子移动都不会返回最终成功 ACK。旧的 in-root
    partial 命名形状继续隐藏且不可寻址，升级后也不会暴露迁移前未完成字节
  - App sandbox 列表不发布符号链接；递归删除只 unlink 链接节点，
    不遍历或删除链接目标
  - 恢复：源指纹验证（下载）、部分偏移验证（上传）
  - ACK 丢失容忍（app-sandbox 上传截断/重放）
- 权限状态提供者
- 诊断报告器（带并发测试覆盖）
- Debug harness Activity（供真机脚本使用的独立 nonce-only 证据路径）
- 产品启动器入口（`DroidMatchActivity`）：提供经过单测的下一步就绪摘要，控制 paired-required endpoint、处理配对审批、列出/撤销不含密钥的已配对 Mac 元数据、处理通知权限、仅在用户点击后授权/重选照片和视频并显示实时“全部/受限/关闭”状态，以及管理 SAF 授权。对端提供的 Mac 名称在进入配对批准、可信列表或撤销确认前会共用一个 UI-only 安全投影：NFC 归一化、折叠空白，移除控制符、Unicode format 与孤立 surrogate；若过滤后没有可见内容则固定显示 `Mac`。经认证的原始名称仍保留在 transcript 与加密凭据 metadata 中，撤销身份仍是 pairing ID。SAF 添加/释放现在会重新读取实时持久授权快照，只有所选稳定 root 确实出现/消失才算成功；系统异常、缺失/畸形快照或撤销后仍存在的 root 只产生固定脱敏提示。列表不可读时，列表与顶部文件夹计数都会标记为暂不可用，并提供显式重试。撤销信任会关闭活动 USB 会话，diagnostics harness 命名仅保留在 debug source。配对重连 proof 成功后会单调更新凭据密文中的最近使用时间；写盘失败只记有界诊断，不会推翻正确认证。媒体 root 的 `can_read` 现按图片/视频实时权限生成并与 `can_write` 独立；该产品权限流程只有本地 JVM/接线/assemble/lint 证据，尚无真机 UI 归档。
- 已配对 Mac 目录暂时不可读时，产品不再把未知的可信 Mac 数量显示为零；该区域作为 polite live region 提供显式重试。纯 `ProductReadiness` 策略独立覆盖“配对目录/SAF 目录”四种可用性组合，因此任一来源不可用都不会伪造另一来源的计数。本项只有本地 JVM/接线/资源证据，不新增真机 UI 声明。
- 针对应用私有数据、配对、SAF、传输和诊断状态的显式禁备份/禁设备迁移规则
- 原创 adaptive vector launcher 标识，支持 Android 13+ monochrome 主题图标

**工具：**
- `tools/check-source-size.py`：全部手写生产、单元测试与 instrumentation 测试 Swift/Java/Kotlin 源码，以及 `tools/` 下 shell/Python 文件统一执行无例外的 800 行上限。新发现的 3277 行真机编排器现为 673 行最终编排器，usage、参数/校验、设备控制、隐私/证据、App Sandbox 探针、结果日志与清理均有独立 helper，且全部满足同一默认上限。
- 传输中媒体撤权 fault hook 现为自包含的新进程，不再隐式依赖父 runner 的 shell 函数。它会丢弃私有 serial、adb 路径、命令参数及平台输出，只发布一条汇总命令状态；离线成功/失败执行测试同时证明独立性与脱敏。既有真机权限归档证据不变，本地回归不新增真机声明。
- 原 783 行产品文件浏览器父视图现以 682 行继续持有 SwiftUI 状态、原生面板、mutation 与队列提交；未改行为的列表/网格渲染归入 140 行无状态 state/actions 组件。93 行 Presentation 纯值独占选择模式/path 对账、按 capability 全选、按行序投影以及仅扣除已受理批量项，不持有 model、Task、panel 或 queue；三项直接测试覆盖该状态。135 行 AppSupport 纯策略另在面板完成时复核精确 query/row/授权/readiness，并让单项/批量下载共用本地 file URL、已存在目标及 canonical/case/width 重名预检。五项直接测试覆盖该边界；这只是本地证据。
- 原 774 行目录浏览 MainActor 现以 628 行继续持有 Published/listing/导航状态、派生 Task、预览、权限判断及按 path 应用 mutation 结果。132 行纯缩略图状态独占 generation/FIFO/active-key/失败/缓存 transition，并让排空中的旧请求继续计入四项上限；三项直接测试覆盖旧 generation 并发、去重/可见性/失败准入及缓存双上限。157 行 MainActor runner 另独占活跃远端 mutation Task 与操作身份且不持有展示或刷新策略。既有目录浏览集成测试原样通过，该次改进使 Swift 库存增至 437；本项不新增真机证据。
- Android App Sandbox catalog 现在任何 listing、mutation、download 或 upload
  provider 操作前，都先经过同一个 65 行无状态 resolver。该边界统一负责
  词法校验、canonical root 约束和逐个拒绝已存在的符号链接 component，不持有
  授权、descriptor 或操作状态；catalog 从 679 行降至 646 行且继续独占 provider 与
  staging 生命周期。三项直接 JVM 测试覆盖普通/未来 entry、root/traversal/保留名别名以及
  直接/嵌套链接，使 Android 库存增至 237。这些只是本地证据，不新增真机声明。
- RPC response、transfer open、upload ACK、有界 download wait 与 readiness gate 共用的
  lock-backed callback/async one-shot 现在会在 cancellation 或 continuation 安装前，原子认领
  唯一消费者。第二次 wait 返回 typed 内部状态错误，不再覆盖活跃 continuation
  使首个 task 永久挂起，也不会进入原先的结果消费后 precondition crash。一项直接回归
  使 Swift 库存增至 438；wire 行为与真机声明均不变。
- `AsyncFramedTcpSession` 现在让 Network.framework 的 completion/timeout/cancellation
  竞态复用同一个 one-shot，不再维护另一套带 trapping missing-result 状态的 gate；既有
  首个结果优先语义继续由 loopback 成功、超时与取消测试覆盖。`AsyncRpcControlClient`
  把协商结果直接绑定在 `ready` state 内，类型上不再存在 ready 但缺少 handshake cache
  的组合。process-local scheduler persistence reload 现在返回既有稳定 `ioFailure`，而非
  终止进程。scheduler admission 现在使用 Swift typed throws，让兼容投影的错误类型可穷尽，
  不再需要兜底进程 trap；一项直接回归使当时 Swift 库存增至 439。wire、真机与发布签名声明均不变。
- `AsyncTimeoutPolicy` 现在拒绝非正数和非有限时长，并在整数或 `DispatchTime`
  转换前饱和超大有限值。transport、RPC deadline、子进程等待以及 harness 的全部
  `--timeout-seconds` 路径都复用该边界；选项缺值也会在连接或启动子进程前失败。
  产品 ADB 发现也会把非法配置时长归一为稳定 `timedOut`，且不会启动 ADB。六项直接回归
  使当时 Swift 库存增至 445。真实登录钥匙串 round-trip 测试现在只在显式设置
  `DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST=1` 时运行；普通门禁使用注入后端，不再请求钥匙串机密。
  产品配对仍正常使用钥匙串。本项不改变 wire、真机或发布签名声明。
- 可信设备展示与凭据选择现在使用两个独立 Keychain 边界。设备页列表永不请求
  generic-password 数据：当前记录校验无密钥 envelope，旧记录只使用 account、label 以及
  Keychain 创建/修改时间属性。被动展示查询使用禁止交互的 `LAContext`；若记录需要认证，
  查询会令展示快照失败而不是弹窗。用户明确连接时，当前记录只读取指纹匹配项；重连成功
  不再改写承载机密的记录，避免最近使用信息再触发授权或使已成功的 proof 失败。由于 macOS 不接受 generic-password
  的 `MatchLimitAll + ReturnData`，旧记录使用逐 account 的有界查询，但共享一个 `LAContext`；
  全部记录校验成功后一次性回填所有 selector，后续连接回到当前单记录路径。首次配对以原子 add-only
  方式发布 provisional 凭据，任何重复 pairing ID 都直接作为碰撞，不读取或更新既有记录；随后把刚写入的
  Core 凭据直接用于 proof，不从钥匙串
  读回机密。回归证明展示读取 0 次、普通重连读取 1 次且写入 0 次、首次配对机密读取 0 次，并证明旧记录
  复用同一认证上下文；
  已认证 coordinator 还会把本 generation 刚完成证明的 Core 凭据直接交给传输 gate，随后
  清除自身引用，因此 scheduler 构建不再第二次读取 Keychain；断开、替换与 keepalive 失败
  继续按既有审计顺序 detach 并失效 gate。当时 Swift 库存保持 460。主动连接卡和无凭据依赖的本地帮助
  会提前说明可能出现的 macOS 钥匙串提示只是在授权读取设备配对密钥，不是索要 Apple 签名
  材料，且 DroidMatch 自身没有密码输入框；读取失败先提供系统对话框允许后重试的路径，再建议
  移除信任并重新配对。配对协议、真机与发布证据均不改变。
- App 进程级 monitor 现在会通过 `proc_pidinfo` 读取 dyld image zero 背后的 vnode，避免
  “进程已启动、monitor 尚未初始化”期间的路径竞态；之后每两秒把该 device/inode 身份与
  同一路径比较，即使没有打开窗口也持续运行，从而发现事务发布已经替换、移除或把它变成非普通节点。
  一次性不可逆回调会使 discovery、可信设备 Keychain 列表/撤销和 session 三个模型入口
  失效，取消或以 generation 拒绝迟到发布，进入既有安全断开，移除所有窗口的旧层级并
  禁用全局刷新；界面只保留双语退出重开提示。monitor 自身不读取 Keychain，也不自动
  启动另一进程。App 生命周期级窗口租约还会让共享 discovery 保持到最后一个活跃窗口离开，
  runtime 失效后拒绝所有新租约。一项 monitor 生命周期/替换/移除/非普通节点回归、一项
  多窗口租约回归与三项模型 gate 回归使当时 Swift 库存增至 465，且不新增真机或签名证据；
  App 发布还会在任何 stale-transaction recovery 前和最终 install/swap 前两次拒绝覆盖
  正在运行的目标；Darwin 同时比较 `proc_pidpath` 的当前 vnode 路径和内核保留的
  `KERN_PROCARGS2` 原启动路径，因此 rename、swap、unlink 均保持可检测，检查失败即
  fail closed。原生行为与运行中事务恢复回归、M0 源码契约固定两处发布 guard，mac-skeleton
  显式运行平台测试；monitor 则兜住最终检查后的窄启动竞态。同一契约还固定映射 vnode、
  App/窗口所有权、全局命令 guard 与三项模型 gate。
- schema-v1 诊断导出器现在会在公开快照输入进入导出边界时再次校验：外部文本保持有界并
  去除控制字符，非法 SDK/存储/电量值会省略，近期错误数夹在文档范围内，负计数器会丢弃。
  一项恶意构造快照直接回归使当时 Swift 库存增至 446，且不新增字段、路径、日志、真机或
  发布签名声明。
- 原 768 行传输 scheduler actor 现以 699 行继续持有存活 task/record/queue、持久化副作用、timer 与发布。120 行纯 execution-event policy 校验 retry attempt、明确 retry 写盘失败回滚、只接受总量稳定的单调进度，并只让当前运行 rate generation 过期；它不持有 task、timer、store、queue、continuation、socket 或 broadcast。四项直接测试使 Swift 库存增至 431；既有 68 行 completion policy 继续对账 executor 退场。本项不新增真机证据。
- 原 755 行原子下载 writer 现以 480 行保留 descriptor 与事务编排；274 行无状态 partial-file 边界负责 no-follow 目录打开、单链接校验、非阻塞 `flock` 和 descriptor/name inode 对账，且不保留 descriptor 或 writer 状态。18 项原子下载专项测试原样通过，当时 427 项 Swift 库存不变；本项不新增真机证据。
- App 自有私有状态原子写入器现把 read/write/remove 事务编排保留在 371 行文件中，未改行为的目录钉住/快照/回滚/恢复 helper 归入 425 行同模块 extension。八项文件系统与跨进程锁专项测试通过；系统调用顺序、错误映射与产品 API 未改变。该次拆分未改变当时 420 项 Swift 测试库存，也不新增真机证据。
- 当前源码库存为 472 项 Swift 测试与 242 项 Android JVM 测试。Android 配对倒计时仍在独立且从无障碍树隐藏的控件中正常显示；阶段专用 polite live region 只在关闭、等待、待批准、已批准、已拒绝等真实变化时更新，不使用 Android 16 已弃用的主动 announcement API。等待批准时 SAS 作为六个独立 ASCII 数字朗读，500 ms 轮询中的未变化阶段/客户端/配对码写入会被抑制。这些计数与下述脚本事务回归只属于本地证据，不新增真机无障碍、Developer ID 或公证结果。
- Android 构建基线保留最低 API 26，并升级为 compile/target API 36、Build Tools 36.0.0、AGP 8.12.2、JDK 17 和带 SHA-256 固定的 Gradle 8.14.5 wrapper。产品 Activity 使用专属 no-ActionBar 主题，避免自身已有标题再次被系统标题栏挤压，使旧版小屏配合无障碍字体缩放时仍能在首屏完整显示第一个安全 USB 操作；并排操作保持等分宽度并共同采用较高标签的实测高度，使缩放/本地化后的第二行既不裁切，也不会与较矮按钮形成错位底边。release 合并 manifest 检查会固定主题边界。可选 `slot-a-704sh-layout-v2` instrumentation 只有显式请求才执行，随后对精确 API/型号/720×1280 物理屏幕/720×1136 App viewport/320 dpi/en-US/1.3 字体缩放和英文两行标签 fail closed，再验证首个操作 bounds、两组操作等高、全部可见按钮的实测文字/内边距高度、完整滚动到页面末尾，以及最终“添加文件夹”操作处于系统导航区上方。专用的显式 serial runner 要求产品包已存在且测试包不存在，先安装容易受 OEM 策略影响的 test APK，再用 `-r` 保留数据覆盖产品 debug APK；此后的所有退出路径只移除测试包并确认产品包仍在。全部 ADB 查询/安装/instrumentation/清理子进程现都有界；交互命令默认 300 秒且硬上限为 600 秒，test APK 仅新建安装超时不会取得清理所有权，也不会继续覆盖产品包。离线失败矩阵覆盖拒装、部分安装、测试/产品/instrumentation 超时、产品覆盖失败、instrumentation 失败、测试数量错误和清理失败，且从不卸载或清空产品包。2026-07-19 已在精确 704SH 配置上完成一次 attended v2 通过；由于没有版本化 result-log producer/validator 和归档日志，它仍只是定向诊断，不新增正式真机 UI 证据。随后一次 current-main 复测遇到 OEM 安装命令在测试包出现后仍不返回；该次运行在不认领包的前提下停止，Android 随后回滚测试包，产品包保持安装。有界 runner 以精确 main `317fe7e` 落地后，进一步的 attended 复测在配置的 120 秒处结束，且测试包并未出现；runner 没有覆盖产品包，事后确认产品包仍在、测试包不存在。两次失败诊断都不新增通过证据；后一次在 704SH 上实机确认了有界失败路径。launcher 在 API 35+ 叠加 system bar/display cutout insets 以适配强制 edge-to-edge。
  测试包安装刻意不使用 `-r`：只有仅新建安装明确成功后 runner 才取得清理所有权；并发出现或失败后所有权不明确的包会原样保留。失败矩阵还会拒绝跳过、负状态、缺状态、测试数量错误、产品消失、包查询错误和临时文件残留。
- `DroidMatchScreen` 主层级拥有的文本和按钮现于支持的 API 范围内固定使用 simple line breaking 并关闭自动连字符，避免 API 26 在源字符串不含连字符时仍把普通本地化单词（例如 `system`）渲染成 `sys- / tem`；系统创建的对话框 view 不属于这项主页面策略。精确 704SH profile 会在既有高度与完整滚动边界之外断言该层级的配置；仅编译不新增真机 UI 证据。
- `tools/build-mac-app.sh` 会在同一文件系统的私有候选目录中组装并验证 App，再通过稳定私有发布事务发布：首次使用 `RENAME_EXCL`，替换已有 App 使用带前后身份复核的 `RENAME_SWAP`。事务 owner 同时绑定 PID 与本次 boot 内的进程启动身份，崩溃或重启后的 PID 复用会判为 stale，不会误报为仍活动。有效的内置 adb 厂商签名保持不变；只有完全未签名的自定义 adb 才补本地签名，已有但无效的签名会直接拒绝；外层 ad-hoc App resource seal 仍绑定精确字节。候选阶段先验证全部静态树、签名与 entitlement，只延后 `adb version`；原子发布后在最终路径运行完整 verifier，失败会在完成标记前恢复旧 App，首次发布则撤回。只有精确的瞬态 `embedded adb is not runnable` 最多额外重试两次。离线 SIGKILL 矩阵覆盖首次安装、发布后验证、durable verified state 写入前后，以及 `rollback-required`、回滚交换和 `rolled-back`；恢复只保留完整验证状态，并对活动、旧版、不一致或不安全事务 fail closed。这不代表电源故障耐久性。输出父目录创建不再使用会修改既有目录 mode 的 `install -d`；离线回归证明非默认 mode 在成功构建前后不变，真实 `/private/tmp` release 构建也不再尝试移除 sticky/world-writable 权限。产品构建与 Swift 测试现共用可写 module cache、外层 sandbox 适配和经 probe 证明的 arm64e 回退。十个精确 RGBA 图标 rendition 会以 no-clobber 方式打包成现代 ICNS，并在签名前由平台解码器重新打开，避开本机复现的 macOS 26.5 `iconutil` encoder 拒绝。离线测试覆盖 packer 及默认/回退参数；dirty release App 已在本机真实构建通过。
- 真实 release App 界面检查确认设备页及四个未认证空态均可访问；文件和诊断现只说明当前连接/认证条件，不再把已经实现的接线写成未来占位，媒体和传输原本已正确。本次检查没有连接或修改已接入的 Android 设备。
- `tools/build-mac-dmg.sh` 会先在私有 initializer 写齐并同步 owner PID、本次 boot 内的进程启动身份、marker 与 state，再以 `RENAME_EXCL` 原子发布稳定事务目录；随后把已验证 DMG/checksum 对置于其中。canonical 缺失以 `RENAME_EXCL` 发布，已有目标以 `RENAME_SWAP` 发布并双向复核，回滚按记录的原状态使用 EXCL/SWAP。恢复按 dev/inode/size/SHA-256 绑定 previous、candidate、canonical 的前后身份；离线测试覆盖新旧初始化的每个边界、活跃 initializer、PID 仍存活但启动身份已 stale 的恢复、真实 building `SIGKILL`、并发插入/替换 fail closed、第一项替换后恢复、完整发布识别、首次发布中断与不确定回滚保留旧字节。伪造或未知布局保持现场并拒绝。这不代表电源故障耐久性。
- `tools/push-main-with-gates.sh`：需显式确认的无 PR 所有者集成命令；只接受干净且可从实时 `origin/main` 快进的 HEAD，在任何远端 push 前先拒绝已知的维护者契约/测试数量漂移，再在唯一且可被保护层认可的临时 `push` ref 上验证同一 SHA，候选 CI 前后均核验 Phase A，并拒绝 main 前移或 run 事件/身份不匹配；它从不 force push，只清理自己创建的 ref，且仅在精确 `main push` CI 也通过、最终 Phase A 仍完整后返回成功。本地预检不能替代托管准入，离线套件覆盖预检拒绝、远端变更顺序和全部 fail-closed 边界
- `tools/run-m1-device-smoke.sh`：以 Swift release 配置构建并调用 Mac harness 的综合设备测试脚本；Git 状态不可读时 provenance 记为 unknown，并生成唯一严格的 `m1-device-smoke-v1` 记录，把已记录的 source/build/APK 身份、slot/API、检查依赖与结果标记、最终 offset、本次实传字节/速率、结果类别与清理意图绑定后再校验私有 staged 日志，最终以不跟随 symlink、不覆盖既有目标的方式发布。只有 clean、rebuilt、完整 revision 的运行属于 `device-evidence`；dirty/unknown/reused 的通过运行与失败运行都只算诊断。脚本含显式启用的 `--dual-download-check`，以及需要独立 fresh 上传目标的 `--mixed-transfer-check`；mixed-download 原子目标使用规范 `/private/tmp`，不经过 macOS 的 `/tmp` 符号链接
- Harness 下载路径含用户或卷 ancestor symlink 时返回稳定且不包含路径的错误。writer 会把 macOS 固定 `/var`、`/tmp`、`/etc` 别名映射到 `/private`，再逐 component no-follow 打开；CLI/真机证据继续统一使用 `/private/tmp` 以便归档比较，这不是产品能力限制。
- `tools/run-m1-throughput-gate.sh`：fail-closed Slot A wrapper；其 pass-only `m1-adb-throughput-v2` 要求先通过 clean/rebuilt 的 `m1-device-smoke-v1` producer，并精确绑定完整 SHA、固定检查计划和重叠指标，再验证命令错误也会拒绝的 current-main provenance、API 26–29、fresh 双向精确 100MiB、raw ADB baseline、请求/实际协商 1MiB chunk、由本次实传字节与耗时反算一致的速率、双向 ≥20 MiB/s，以及固定受管零数据 hash 与下载/远端上传 SHA-256 在计时窗口外完全一致；随后还需通过隐私受限输出、清理验证、staged 单日志严格校验和原子 no-clobber fixture 发布。在严格 preflight 之后，wrapper 失败时只有私有 `m1-device-smoke-v1` producer 已先独立通过 validator，才可发布独立的 fail-only `m1-adb-throughput-diagnostic-v1`；组合归档内嵌该已校验 producer 记录，并保留其可用指标、固定失败 stage、source/expected/origin 绑定、运行后 provenance、producer exit/result、已取得摘要与聚合清理状态，进程仍非零。producer 无效/缺失、隐私或 validator 失败、no-clobber 竞争都不发布诊断。吞吐 v1 继续拒绝，只有通过的 v2 能满足 Slot A
- `tools/run-product-usb-insertion-smoke.sh`：人工执行的 `m1-product-usb-insertion-v1` profile；包含起钟前再次确认不存在、先读单调时钟再发插入信号、精确发现卡片 AX 标识、运行中 release bundle provenance、物理动作确认，以及 no-clobber、固定描述符、先校验的 fixture 发布
- `tools/check-product-usb-insertion-logs.sh`：严格校验产品插入 fixture 的结构、provenance、隐私、时延和计数
- `tools/m1-fault-proxy.py`：用于故障注入的本地帧代理
- `tools/check-m1-skeleton.sh`：CI 验证
- `tools/check-m1-run-logs.sh`：不回显命中内容的隐私拒绝，以及对普通、吞吐通过与吞吐诊断 profile 的目录或 staged 单日志严格语义校验；新普通日志必须使用 `m1-device-smoke-v1`，89 份无 profile 历史 fixture 仅按 `legacy-v0.sha256` 冻结的精确路径与字节接受
- 本次吞吐失败诊断路径只增加离线工具覆盖；没有新增真机 fixture，89 份日志的归档计数不变，也不会关闭任何剩余 M1 阻塞项
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
- Mac 与 Android 均已提供不暴露密钥的信任管理。Mac 撤销会等待活动会话完全断开后再删除 Keychain 记录；删除失败或返回 false 时保留可信设备行、把快照标记为不可用，并只显示固定脱敏指引。已开始的 Keychain 列表查询可以在界面超时后返回，但中途发生撤销会使该结果失效，旧元数据不能重新发布已移除的行。Android 撤销会关闭活动 USB 会话。Slot C 普通 App 首次配对、已配对重连、sandbox 产品认证及需要人工批准安装的真实 Android Keystore 行为均已归档。

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
  - `AsyncTransferScheduler` 已提供 FIFO、两任务并发上限、buffering-newest queued/running/retrying/pausing/paused/interrupted/终态快照、跨重试单调的接收端确认 bytes/total、两秒时间加权近期吞吐、重试可见性、完成等待、取消和检查点暂停/继续。默认仍为进程内队列；`restoring(...)` 可选启用版本化原子 manifest，在 executor 启动前先落盘 queued→active，并可把所有启动路径持续锁在产品授权 readiness 之后。它只恢复 sidecar 匹配的 download/app-sandbox/SAF 任务，并把包括 MediaStore 在内的不安全 active 工作保留为禁止自动重放的 `interrupted`；修复损坏 manifest 后可在同一 lease/readiness 事务中重试，不再要求重启进程。会话挂起时，不可暂停的 active executor 会保持未 settle 到真正退场，使已不可回滚的本地 download 能以 completed 收口而不会制造不可继续的 interrupted 行。排队 pause 是直接挂起；运行中检查点 pause 只关闭自己的 coordinator session，再以同一 job/transfer identity 入队。该本地策略不声称 Android wire upload pause。
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
| SAF 上传恢复 | ✅ Slot C 通过 | Transfer-id 隐藏 partial；10MiB resume 测得 27.36 MiB/s |
| 权限拒绝映射 | ✅ Slot C/D provider 行为通过；产品媒体 UI 待真机归档 | Media 列表撤销返回 `permissionRequired`。Android 现会在每个活动 provider chunk 前主动重查对应图片/视频的 MediaStore access 或精确 SAF tree 权限，并在 SAF 最终发布前再查一次。Android 14+ selected-media access 还会验证当前具体条目仍可见，本地测试覆盖“取消当前条目但保留另一条目”的情况。产品启动器现仅由用户操作触发媒体授权/重选，并发布实时媒体 root 读取能力；Mac 会阻止不可读导航，但不会丢弃合法的 root 上传。这些 UI/root capability 变化目前只有本地自动化证据。拒绝会关闭 route/租约，同时 control 与后续替代传输仍可用。底层 provider 竞态产生的 `SecurityException` 在 MediaStore/SAF 归一为 `permissionRequired`，app-sandbox 归一为 `internal`。系统权限变化仍可能先拆除 endpoint，使 Mac 只能收到 transport loss；Slot C/D 已归档这一合法结果并恢复授权。产品权限/重选与 SAF 传输中途撤权尚无真机归档。 |
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
- **统一源码规模债务已关闭，更广泛的治理债务仍在：** 全部手写 Swift/Java/Kotlin 生产与测试源码及 shell/Python 工具均满足无例外的 800 行预算，所有产品/CLI 网络路径均使用 async transport。原 3277 行真机 runner 现为 673 行最终编排器并依赖有界 helper。文件浏览工具栏、传输持久化映射、transfer frame、scheduler 测试支持及本地 framed-server 的状态/读取器/响应值已有明确边界，贡献与 PR 交接证据由 CI 强制检查，但单一 GitHub owner 的发布权限仍然集中；见[结构性债务基线](technical-debt.md)
- **多流支持范围有限：** 普通 CLI download/upload 仍为单传输；`dual-download-smoke` 与 `mixed-transfer-smoke` 是显式 probe。混合方向及预检后的 4 chunk / 2 MiB upload window 已有本地 TCP、真机脚本入口和 Slot C 归档真机结果；Slot A/D 仅在需要区分设备特性时再扩展。
- **重试默认单次：** `--retry-on-transport-loss` 默认仍只重试一次以保持向后兼容；需显式传 `--max-retry-attempts N` 才启用多尝试恢复队列
- **可恢复 SAF partial 生命周期：** 不可恢复上传非最终关闭会删除未完成文档；
  暂停或等待重试的 transfer-ID 上传会有意保留隐藏 partial。产品永久取消、终态历史
  移除与 shutdown 会持久化经过认证的精确 tuple 清理；同一设备重连后只幂等删除归属
  DroidMatch 的 App Sandbox/SAF 私有 partial，最终目标永不符合删除条件。Android
  provider 不做猜测式孤儿扫描，因此旧 harness partial、不可恢复的损坏队列状态，或 Mac
  永不重连的任务仍需显式清理。smoke runner 另通过 protocol delete mutation 清理直接
  root 单文件 SAF 目标；进程内 document-token 嵌套目标仍保持显式/手动清理。
- **MediaStore fresh-only：** 不支持上传恢复（返回 unsupportedCapability）
- **相册首次索引成本：** 为保持 API 26+ 一致语义，首次相册列表会流式扫描 MediaStore bucket 列，但内存只随相册数增长；有界 LRU 会避免每个相册封面重复扫描，服务重启后的旧 token 解析可能再触发一次扫描。API 35/36 目前只有本地构建证据，尚无该 UI 的真机归档。
- **仅 ADB loopback：** Android endpoint 拒绝非 127.0.0.1 客户端
- **需要 debug harness Activity：** 某些 OEM 设备在没有前台 Activity 的情况下冻结服务 accept() 线程
- **Android 15 后台服务额度：** ADB loopback endpoint 使用 `dataSync` 前台服务类型，每 24 小时最多在后台运行 6 小时。超时后会关闭 endpoint 并停止 non-sticky service；未来 AOA 路径只有在取得真实 USB accessory grant 后才能使用 `connectedDevice`。

## 测试结果摘要

截至 2026-07-19，`fixtures/m1-runs/` 包含：
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
- 单测覆盖异常路径：stale 下载恢复 source fingerprint、invalid page token、oversized envelope、flagged envelope-payload CRC mismatch、bad transfer-chunk CRC32、终止性畸形 chunk/ACK/provider/capability 清理、有界迟到窗口吸收、方向错配、交叉 request/stream ID、活动 MediaStore/SAF read grant 丢失、SAF write grant 在 chunk 或最终发布前丢失，以及对应 route/租约恢复
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
