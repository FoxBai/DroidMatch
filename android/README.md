# DroidMatch Android 端

这里是 DroidMatch Android 端实现目录。

M1 起点：

- 先构建前台服务骨架，不构建完整应用体验。
- 实现 ADB endpoint、RPC dispatcher 和 length-prefixed `RpcEnvelope` 编解码。
- 暴露设备信息、权限状态、目录列表和基础文件传输 provider。
- 按 `docs/android-permissions.md` 使用 SAF / MediaStore-first 权限模型。
- 记录服务状态、权限状态、传输状态和最近错误，供 Mac 端诊断导出。

AOA 入口在 ADB M1 harness 可用后再接入同一套协议面。M0 规格已经收口，见 `docs/m0-closeout.md`。

M1 还实现了与活动 transfer cancel 分离的认证上传 partial 清理：请求必须通过配对 proof
并同时具有 `FILE_WRITE`/`RESUMABLE_TRANSFER`，按 destination、transfer ID 与 expected
size 精确派生 App Sandbox staging 或 SAF hidden document，和活跃 writer 共用目标 lease。
缺失是幂等成功；最终目标和 fresh-only MediaStore 永远不属于该删除路径。

M1 暂时把 service、transport、protocol、providers、permissions 和 diagnostics 骨架放在 `app.droidmatch.m1` 包内；M1 通过后再按 `docs/architecture.md` 拆模块。

## 当前已实现

- `ForegroundConnectionService`：创建本地化的前台服务通知，产品入口默认启动 `PAIRED_REQUIRED` ADB endpoint，debug harness 显式保留 `NONCE_ONLY` 证据模式；认证模式或端口变化时会关闭旧连接并重建 endpoint，进程被杀后不创建缺少启动参数的空闲 sticky service，并在 Android 15 `dataSync` 超时时立即释放 endpoint 后停止自身。
- `AdbEndpoint`：只在 `127.0.0.1` 上监听产品或 debug harness 指定端口，设置 handshake/idle timeout，并把连接交给 dispatcher；一次性 lifecycle lock 会原子化 bind 发布、client admission 与 teardown，最多同时准入 4 个 queued/running session，饱和连接在 ClientHello 前直接关闭，停止后的晚到 accept 不会进入 dispatcher。
- `FramedIo`：读写 `uint32_be length + payload` frame，最大 4 MiB；发送端把 4 字节 header 合并为一次 bulk write，再写 payload，避免旧 Android 上逐字节跨 Java/native 边界，同时保持线格式不变。
- `RpcDispatcher` / `RpcEnvelopeValidator`：负责 envelope/version 校验、bit-0 可选 payload CRC 的零整块复制校验、transfer request/stream 双 ID 绑定、每连接 session phase 顺序和 READY 后 capability 二次守门；flagged CRC 错误在 nested payload/handler 前拒绝，未设置 bit 0 时继续忽略 CRC 和未知 flag。READY 前任何 envelope/CRC/Hello/auth/pairing 拒绝都会完成 pending pairing、清零临时状态并关闭 socket，后续正确 Hello 不能复活，因此周期性坏帧不能刷新 handshake window 并占满 4 个槽；READY 后的 request-local/route-local 错误仍保持会话与 sibling route 可用。帧收发总数只累计到两个固定结构化 counter，不在传输热路径写 Info logcat；会话开关、超时和错误日志仍保留。
- `RpcAuthenticationHandler` / `RpcPairingHandler` / `RpcSessionState`：前者处理 nonce-only 与 `AWAITING_HELLO → AWAITING_AUTH → READY` 重连，配对 handler 独占 `PAIRING_AWAITING_CONFIRM → PAIRING_AWAITING_FINALIZE` 的 start/confirm/finalize、可见审批和最终确认后持久化；两条路径共享同一个进程级限速器，dispatcher 继续独占阶段顺序，session state 在 READY/CLOSED 前清零临时密钥。
- `RpcTransferOpenHandler` / `RpcTransferHandler` / `RpcTransferStreams` / `RpcTransferRegistry`：在 dispatcher 完成 envelope 与 session phase 校验后，分别负责 open 解析/能力与双流准入/provider handle 初始安装、chunk/ACK/cancel/pause 动作、4 chunk / 2 MiB 窗口与 ACK 安全恢复边界、会话级 download/upload handle 身份和 teardown；open handler 与活动流 handler 共享唯一 registry，上传 chunk 直接从 envelope `ByteString` 解析，不再复制整块 payload。畸形 nested payload、ID/方向/offset/final-ACK 边界、chunk 大小/CRC、capability 错配或 provider 失败在回 correlated error 前终止并释放本 route 的 handle、双流名额与上传目标租约，control session 和 sibling route 保持可用。完成/cancel/pause/error 后只保留有界的 session-local route ID marker：最近 16 条 route 各最多吸收 4 个已在途 chunk/ACK，不保留 provider handle，超额或普通未知流仍返回 `NOT_FOUND`，连接关闭会清理 marker 与剩余全部 handle。10 项 envelope/终止性测试把总数提升到 195；5 项活动 provider 授权测试使其达到 200，4 项媒体权限策略与 root capability 测试使其达到 204；3 项 handshake/idle timeout 策略与 endpoint 接线测试使总数达到 207；3 项 App Sandbox 根别名与符号链接准入测试使总数达到 210；2 项 transfer-scoped staging 隔离测试使当时总数达到 212；1 项非目录 staging 节点测试同时覆盖普通文件与符号链接 fail-closed，使总数达到 213；1 项 setup fail-closed/不可复活测试使当前 Android 单元测试总数达到 214 项。
- 上述 214 项是 setup fail-closed 收口时的阶段库存；继续加入分页/scan 上限、
  App Sandbox staging 节点、SAF rename provenance、配对 last-used、传输边界与 SAF
  路径准入抽取及永久 partial 清理覆盖后，当前 Android JVM 单元测试库存为 242 项。这些是离线证据，不新增真机声明。
- `SessionAuthenticator`：与 Mac 端字节级一致的 canonical transcript、SHA-256、角色隔离 HMAC proof、HKDF session key 和常量时间 proof 校验；已接入 pairing reconnect protobuf 与 reconnect authentication handler。
- `PairingCredentialRepository` / `SessionAuthenticationMode`：paired 状态机的安全存储边界和显式策略。产品 service 默认选择 `PAIRED_REQUIRED`，debug harness 必须显式请求 `NONCE_ONLY`；一次成功重连会单调推进加密 record 的 `lastUsedAtUnixMillis`，更新失败只记录有界诊断而不推翻正确 proof。Slot C 已归档经手机端人工批准安装后的真实 Keystore identity/wrapping key 不可导出与 record 重开/撤销证据；本轮 last-used 更新只有 JVM 证据。
- `PairingAuthenticator` / `PairingKeyAgreement`：使用平台 P-256 ECDH、固定 canonical transcript、两路 HKDF、无偏六位 SAS 和 client/server/final 三类 HMAC confirmation；Swift/Java 共用 `pairing-v1.properties` 固定向量。
- `AndroidDeviceIdentity`：在 Android Keystore 中维护稳定、不可导出的 P-256 签名私钥；首配 response 返回公钥并对包含该公钥的 canonical transcript 签名，Mac 校验后把公钥 SHA-256 作为设备指纹。
- `AndroidPairingCredentialStore`：32 字节 pairing key 由不可导出的 Android Keystore AES-GCM key 包装；pairing ID、设备身份指纹、名称和时间戳全部作为 AAD 认证，密文存入禁备份的私有 SharedPreferences。pairing handler 只在 final confirmation 验证后写入。
- `AndroidDeviceInfoProvider`：返回设备型号、Android 版本、SDK、数据分区容量、电量和 M1 权限状态。
- `PairingApprovalController` / `PairingAccessibilityPolicy` / `PairedDeviceManager` / `ProductDisplayName` / `ProductReadiness` / `DroidMatchActivity`：进程级 controller 默认关闭；产品 Activity 顶部用可测试的纯状态判定展示“开启 USB → 配对 Mac → 可传输”的明确下一步及可信 Mac/可选文件夹计数，可显式启停安全 USB endpoint，并仅在 paired endpoint 已监听时允许用户打开 120 秒配对窗口。UI 只显示客户端名和六位 SAS，可批准/拒绝 pending attempt、查看按最近使用排序的已配对 Mac、撤销单项信任并立即关闭现有 USB 会话。配对阶段文本作为只在状态真正变化时更新的 polite live region；视觉秒数在独立且从无障碍树隐藏的控件中按秒更新，因此不会反复打断 TalkBack，也不使用 Android 16 已弃用的主动 announcement API。六位 SAS 仅在等待批准时进入无障碍树并逐位朗读，稳定客户端名/配对码不会因 500 ms 轮询重复写入。对端名称在配对批准、可信列表和撤销确认共用同一 UI-only 安全投影：NFC 归一化、折叠空白，移除控制符、Unicode format/bidi 与孤立 surrogate，最多保留 120 个 Unicode code point，真实截断在上限内显示省略号，过滤为空时显示固定 `Mac`；原始名称仍保留在认证 transcript 与 AAD 保护的凭据记录中，配对 ID 继续是撤销身份。SAF 文件夹列表与移除确认也复用该投影并使用本地化空名称 fallback，动作仍由原始 stable root ID/tree grant 定位。即使加密凭据删除写盘失败，撤销动作仍会请求关闭 endpoint，避免已有认证会话继续运行。已配对 Mac 列表暂时不可读时，不会把未知数量误报为零；对应区域以 polite live region 展示固定说明和显式重试，顶部计数会独立区分“可信 Mac 不可用”“文件夹不可用”及两者同时不可用。照片/视频权限只在用户点击后请求或重选，页面以“全部/受限/关闭”显示恢复前台后的实时状态。SAF 文件夹仍由独立系统 picker 管理；添加或移除后会重新读取系统持久授权，只有目标稳定 ID 确实出现或消失才算成功。系统调用异常、空/畸形快照和未生效撤销均只显示固定脱敏提示；授权列表不可读时，文件夹区与顶部计数都显示暂不可用并提供显式重试，不暴露 tree URI 或平台异常。
- `AuthenticationRateLimiter`：首次配对和重连使用进程级指数退避；重连同时按 pairing ID 与全局失败压力守门，防止随机 ID 轮换绕过。状态五分钟空闲后过期、最多跟踪 256 个 ID，锁定期仍走相同 challenge/unauthorized 外形。
- `DmFileProvider` 负责 M1 root、SAF process-local token cache、catalog 组装/路由与跨会话上传目标租约；`ProviderMediaCatalog`、`ProviderSafCatalog`、`ProviderAppSandboxCatalog` 独立定义 package-private provider 端口和 fail-closed 空实现，具体 Android catalog 不再反向依赖 facade 接口。`ProviderPathRouter` 负责 logical path/target，并在 filesystem canonicalization 前拒绝精确 `.` / `..`、空中间段、NUL 与绝对 relative path；65 行的 `AppSandboxPathResolver` 是 listing、mutation、download 与 upload 共用的唯一 filesystem 准入边界，统一完成 canonical-root 约束并拒绝任何既有符号链接 component；646 行的 `AndroidAppSandboxCatalog` 继续独占 provider 行为与 staging 生命周期。`ProviderPagePolicy` 独立负责 query-bound opaque page token、分页上限和默认排序；`ProviderBoundedPageSelector` 让 App Sandbox/SAF 在 Java 层最多保留排序前 `offset + pageSize` 个候选，前者还以流式目录扫描避免完整 `File[]`，不发布协议无法安全表示的符号链接；直接寻址链接 component 会 fail closed，App Sandbox 递归删除普通目录时只 unlink 链接节点，绝不遍历链接目标。App Sandbox 下载从已打开描述符 `fstat` 出 size/mtime/device/inode/ctime，后面三类身份只进入不可逆 etag，因此同大小、同 mtime 的原子替换仍会让 resume 指纹失效，而且不会为大文件增加一次全量预哈希。`dm://roots/` 逐次按图片/视频的实时授权生成媒体 `can_read`，相册跟随图片权限；`can_write` 独立，API 26–28 因未声明旧式写权限而不宣称 MediaStore 上传。`AndroidMediaCatalog` 把 limit/offset/sort/search 下推给 MediaStore，并继续唯一持有 resolver/URI、按图片/视频区分的 full/selected/denied 实时权限、selected 模式精确条目可见性、cursor 生命周期、token cache、错误映射、缩略图、传输、pending row 与清理；`MediaStoreCursorReader` 只扫描已打开 cursor，保留 typed page/album/lookup/metadata 的 null/default、时间单位与 `hasMore` 语义。`AndroidSafCatalog` 负责 persisted tree permission、document query/download、mutation admission 与 parent metadata 验证；`AndroidSafUploadOpener` 独占已授权上传的 final/partial 创建、精确 child 查找、ACK-loss 截断、writer 交接和交接前清理，纯 `SafUploadOpenPolicy` 直接覆盖 fresh/restart/resume 与 partial kind/size 决策；`SafDocumentCursorReader` 仍只用统一六列 projection 把已打开 cursor 解码为 typed item/metadata/child，不持有 resolver、URI、权限、cursor 生命周期或错误映射。`ProviderAuthorizedTransfers` 在 MediaStore/SAF 下载和 SAF 上传每个 chunk 前重查实时授权；Android 14+ selected-media 模式还会重查当前具体条目，避免取消当前条目后旧 FD 继续可读，SAF final bytes 写入后还会在 flush/close/rename 前再次检查；拒绝会先关闭句柄，再由 dispatcher 释放 route 和上传租约。底层 provider 竞态产生的 `SecurityException` 同样会映射为不泄漏细节的 `ERROR_CODE_PERMISSION_REQUIRED`；若系统撤权先杀死 endpoint，Mac 仍可能只观察到 transport loss。这些权限强化不改变 CRC、offset、线格式或严格的 4 chunk / 2 MiB 窗口。
- `CreateDirectoryRequest`：认证会话持有 `file_write` 后可在 App Sandbox 或可写 SAF 目录创建直接子目录；App Sandbox 不隐式创建缺失父目录，SAF 只接收进程内 opaque parent token，MediaStore 明确返回不支持。
- `RenamePathRequest`：App Sandbox 只允许 canonical 同父目录重命名并保持文件/目录 kind；SAF opaque document token 会绑定列出它的真实 parent document，只允许同 root、同 parent 的平台 rename，跨目录、parent provenance 缺失、MediaStore 与只读 provider 都会在 catalog 调用前拒绝。
- `DeletePathRequest`：禁止删除 App Sandbox/SAF root；非空 App Sandbox 目录和全部 SAF 目录必须显式携带 `recursive=true`，文件与目录 kind 不匹配时拒绝。
- `ProviderPagePolicy` / `ProviderBoundedPageSelector`：精确 listing 默认 200、单页最多 1,000 条；query-bound token 只允许到每个精确查询 10,000 条的检索范围，并在加法溢出或伪造高 offset 时返回 `INVALID_ARGUMENT`。若 provider 在最后一个可接收窗口仍报告 `hasMore`，统一响应边界会丢弃该不完整页并返回仅含稳定 `UNSUPPORTED_CAPABILITY` 的错误，绝不以空 token 把截断列表伪装为完整。App Sandbox/SAF 最多保留排序前 `offset + pageSize`（不超过 10,000）个候选，同时最多检查 25,000 个含过滤项的 provider row；超过 scan 上限返回同一稳定有界能力错误，避免不匹配搜索造成无界工作。
- App Sandbox fresh upload 清理只删除匹配的普通 staging partial；若同名节点已变成目录或符号链接，则保留现场并 fail closed。递归删除改用不启用 `FOLLOW_LINKS` 的 `walkFileTree`，运行中出现的符号链接仍只作为叶节点删除，不遍历目标。
- `ListDirRequest.search_query`：App Sandbox/SAF 在排序分页前执行 Locale.ROOT 不区分大小写过滤，MediaStore 使用已转义 `%`/`_`/`\\` 的 selection；搜索词绑定进 page token 且最大 256 字符。
- `ThumbnailRequest`：仅接受 MediaStore 图片/视频 opaque path；API 29+ 使用 `ContentResolver.loadThumbnail`，API 26–28 使用系统缩略图接口，按最长边 32–512 px 缩放并以最多 512 KiB 的 JPEG 响应返回，不读取并传输完整原文件。
- 图片相册：`dm://media-images/albums/` 在 API 26+ 按 MediaStore bucket 聚合图片；bucket ID 只在 Android 内参与 selection，Mac 只见严格校验的 96-bit 哈希 token。聚合在过滤/排序后分页，相册内图片复用平面视图的 canonical `dm://media-images/media/<id>` 身份；相册缩略图只查询该 bucket 最新可用图片并复用有界缩略图编码，不读取原图。当前真机相册证据最高到 API 34，API 35/36 只有本地构建与回归证据。
  - 为兼容 API 26，首次相册列表会流式扫描轻量 bucket 列并只保留每个相册一条聚合状态；同时填充最多 4096 项的进程内 LRU token→bucket 映射。随后可见封面和进入相册通常 O(1) 解析，服务重启后的旧 token 才回退到一次流式扫描。
- `MediaPermissionPolicy` / `MediaPermissionController` / `PermissionStateProvider`：分别负责纯 API 分级与 fallback 决策、仅由用户操作触发的平台请求/设置跳转，以及不缓存的实时 full/selected/denied 状态；诊断仍只发布粗粒度权限状态。`DiagnosticsReporter` 的计数器有 JVM 并发测试覆盖。
- backup/data-extraction rules：API 26–30 full backup、Android 12+ cloud backup 和 device transfer 均显式排除全部应用私有域，防止未来 pairing key 包装密文、SAF 状态、传输 sidecar 或诊断数据被迁移。
- Gradle app skeleton：保留 API 26 最低版本，以 API 36 编译并作为 target，固定 Build Tools 36.0.0、AGP 8.12.2 和带 SHA-256 的 Gradle 8.14.5 wrapper；可构建 debug/release/test APK，包名为 `app.droidmatch`，代码 namespace 为 `app.droidmatch.m1`。
- Android protobuf codegen：Gradle 从根目录 `proto/` 生成 `app.droidmatch.proto.v1` Java lite classes。
- launcher 入口：安装后启动器中显示 DroidMatch 图标，打开 `DroidMatchActivity` 完成安全连接、配对、通知、照片/视频与 SAF 授权管理；它仍不是完整文件管理器。产品 Activity 使用专属 no-ActionBar 深色主题，避免重复标题挤压 API 26 小屏/大字体下的首个安全 USB 操作，同时继续由系统为 API 26–34 保留状态栏与导航栏空间；并排按钮只固定等分宽度，高度随无障碍字体换行自适应，不裁掉第二行。本轮媒体授权/重选只有 JVM、assemble 与 lint 证据，尚无产品 UI 真机归档。
- launcher visual：单一 adaptive vector 使用深石墨背景、冷玉色/暖白设备端点与暖色匹配桥；Android 13+ 提供 monochrome themed icon，不再维护重复密度 PNG。
- Android 15+ 强制 edge-to-edge 时，launcher 会把 system bars 与 display cutout insets 叠加到固定内容 padding；API 26–34 保持原 padding，避免旧系统重复留白。这是本地编译/接线证据，不是 API 35/36 真机 UI 归档。
- debug harness overlay：debug APK 只额外导出 `DebugHarnessActivity`，便于用 `adb shell am ...` 启动真机 smoke；Activity 再通过应用内显式 intent 启动始终不导出的 service。

当前支持 download 方向的窗口化 open/chunk/ack（每个 stream 最多 4 个 chunk 或 2MiB in-flight），并在同一会话内把上传/下载活跃流总数限制为 2；第三条合法 open 会收到 typed concurrency error，方向和 capability 校验先于并发上限。Mac 的 `dual-download-smoke` 已用本地 TCP 端到端测试证明两条下载流可按 stream ID 交错路由，且双流活跃、首块未 ACK 时 heartbeat 不会被数据面饿死；Slot C 已归档 `--dual-download-check` 与混合方向真机结果，仅在需要区分设备特性时再扩展到 Slot A/D。

同一会话的活跃 `transfer_id` 在上传/下载之间也必须唯一，避免 cancel/pause 命中不确定；cancel 会释放下载 reader 或上传 writer，download pause 只返回最后 ACK 的安全恢复 offset，不会把已发送但尚未确认的窗口数据计入。

ADB endpoint 可同时服务多个 loopback 会话，但共享 `DmFileProvider` 会为每个 canonical App Sandbox、SAF 或 MediaStore 上传目标持有唯一进程内租约。第二个同目标 open 会立即返回 `ERROR_CODE_ALREADY_EXISTS`，不同目标仍可并行；open 失败、write abort、final commit、cancel/close 和 session teardown 都会释放租约。

单流路径还支持活动 download cancel/pause、带 source fingerprint 的非 0 offset resume 请求，app-sandbox fresh/resume upload、fresh MediaStore upload、fresh SAF upload/resume，以及 MediaStore fresh-only upload resume 边界 probe；Mac harness 能在 transport close/timeout 后用 sidecar 对 download 和 app-sandbox/SAF upload 自动重试，真机脚本可用本地 frame proxy 注入首条传输连接断开并要求恢复成功；app-sandbox upload 对 ACK 丢失窗口会把 partial truncate 回 Mac 已确认 offset 后允许重发。Mac 产品异步层已通过本地 TCP 的原子文件下载、取消保留 partial、resume offset 竞态拒绝、四块窗口化上传和取消后 heartbeat 测试；真机混合流、产品 sidecar/recovery scheduler 和完整真机传输矩阵仍会继续收口。

MEIZU M20 的已准备 10MiB MediaStore 测试项先归档了修复前被二次 inactive-route 错误遮蔽的失败；Mac send-admission 与 Android chunk-time 权限映射修复后，同场景复测以 `transport_lost_after_revoke` 通过并恢复原权限。后续归档的清理核验确认精确的一次性上传文件名对应 row 为零，默认 Mac download/partial/sidecar 产物也为零。该结果证明回归路径，不代表所有 OEM 都会在撤权时返回同一种 transport/typed error。

## Provider Upload 语义

M1 upload 入口统一走 `OpenTransferRequest(direction=UPLOAD)`，Android 端只信任 `destination_path`：

- App sandbox：`dm://app-sandbox/<relative-file>` 写入 app 私有 `files/droidmatch-sandbox`。partial 位于公开 root 之外的 sibling 私有 staging 目录，文件名只包含 destination / `transfer_id` / expected size 的域分离摘要。fresh upload 会清理同一逻辑 destination 的旧 private-staging partial；旧 transfer identity 再恢复会稳定返回 `NOT_FOUND`，不会复用新内容前缀。`upload --resume` 只通过 `NOFOLLOW_LINKS` channel 打开精确 transfer-scoped 普通 partial，符号链接会在截断或写入前被拒绝。partial 至少要达到 requested offset，如果更长，Android 会在同一 channel 上 truncate 回 requested offset 以支持 ACK 丢失后的重发；final chunk 会先对这一个 channel 执行 `force(true)`，再关闭并以同文件系统原子替换目标。同步或 `ATOMIC_MOVE` 失败都会在最终 ACK 前返回稳定内部错误、保留 partial 并保持旧目标不变，不会把 `flush/close` 或普通覆盖移动误当成耐久提交。公开 root 内旧式 `.droidmatch-upload-part` 命名空间继续保留为隐藏且不可直接寻址；fresh upload 不会删除这些升级遗留项，新 App Sandbox 目标也不能使用该保留命名。
- MediaStore：`dm://media-images/<display-name>` 和 `dm://media-videos/<display-name>` 是 fresh-only。`ProviderMimeTypes` 以与 Mac Core 对齐的显式扩展名表解析图片/视频 MIME；`ProviderTransfers` 在能力检查、租约和 catalog open 前拒绝未知、无扩展、歧义 `.ts` 或错分类名称，`AndroidMediaCatalog` 在 `insert` 前再次使用同一策略，绝不把任意文件 fallback 成 JPEG/MP4。Android 10+ 会插入 pending row，分别落在 `Pictures/DroidMatch/` 和 `Movies/DroidMatch/`；final chunk 后只有 `IS_PENDING=0` 恰好更新一个目标 row 才会返回最终成功 ACK，零行更新按提交失败处理并清理未发布 row。非 final close 或 open/write 失败同样会删除插入的 row。MediaStore upload resume 目前返回 `ERROR_CODE_UNSUPPORTED_CAPABILITY`，可用真机脚本的 `--upload-resume-unsupported-check` 记录这条边界。
- SAF：`dm://saf-<stable-id>/<display-name>` 写入授权 root，`dm://saf-<stable-id>/doc/<directory-token>/<display-name>` 写入已 listing 过的 SAF 目录 token。Android 只接受有写权限且支持 create 的目录；RPC fresh upload 会创建由 `transfer_id` 派生的 hidden partial 文档，非 final close 保留 partial；`upload --resume` 要求 partial 文档至少达到 Mac 最后持久 ACK，若 provider partial 超前则通过可写 seekable descriptor 截断到该 offset 后重放，partial 过短会拒绝，provider 不支持安全截断时返回 `ERROR_CODE_UNSUPPORTED_CAPABILITY`；final chunk 后 rename 成用户目标文件名。

`RpcTransferOpenHandler` 会把 `OpenTransferRequest.transfer_id` 传到 provider upload 层；App Sandbox staging identity 和 SAF partial document key 都必须使用这颗稳定 transfer id，而不是只从用户可见 display name 推导。

真机 smoke 的 `--cleanup-upload-destination` 现在也会通过 fresh protocol delete session 自动清理直接 root 下的单文件 SAF 目标（`dm://saf-<stable-id>/<name>`）。嵌套 `dm://saf-<stable-id>/doc/<directory-token>/<name>` 仍不自动清理，因为 token 是进程内 capability；递归目录、临时 root 授权撤销和可恢复 hidden partial 仍需显式核验。

本地用 `android/gradlew` 生成 protobuf Java lite classes、运行 Android JVM tests、编译 Android app / instrumentation test APK 并运行 lint：

```text
bash tools/check-m1-skeleton.sh
```

Android-only CI job 会设置 `DROIDMATCH_SKIP_SWIFT=1`，因为 Mac harness 已由独立 Swift job 覆盖。

`AdbEndpointLifecycleTest`、`AdbEndpointAdmissionTest` 与 `AdbEndpointLogTest`
分别覆盖晚 bind/停止后 accept/一次性关闭、4-session admission/release/worker 拒绝、
以及不泄漏异常详情的日志标签；三者共享唯一的 JVM latch/socket support seam。
这些是离线回归测试，不是新的真机或吞吐证据。

原 `DmFileProviderTransferTest` 的 21 项测试按所有权拆到 App Sandbox mutation/listing、
App Sandbox transfer 与 MediaStore/通用 transfer 三个套件；该次拆分未改测试正文和
当时 180 项 Android 单元测试库存，且不增加任何真机能力声明。

也可以单独构建 APK：

```text
cd android
./gradlew --no-daemon :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:assembleDebugAndroidTest :app:lintDebug
```

仓库门禁会额外传入 `--warning-mode fail`。项目 DSL 或固定插件产生的 Gradle
deprecation 会在升级 wrapper 前成为明确失败，不会长期淹没在构建日志里。
`gradle/verification-metadata.xml` 还会以默认 strict 模式校验插件、POM/module metadata、
编译/测试/runtime artifact 的 SHA-256；CI 开启 verbose 报告，任何未审查的新依赖或
同坐标字节漂移都会失败。当前基线由官方配置仓库做 TOFU bootstrap，不冒充独立 PGP
来源认证。升级依赖时必须用完整 gate task 集执行
`./gradlew --write-verification-metadata sha256 ...`，审查 diff 后才能提交。
`protoc` 是平台分类 artifact：基线同时固定本机 macOS arm64 与 GitHub Ubuntu x64
版本；Linux SHA-256 由 Maven Central 固定坐标独立下载复核，新增 runner 架构必须显式补审。
门禁同时检查 unsigned release APK 的 launcher badging，并要求 release 合并 manifest
不包含仅属于 debug source set 的 `DebugHarnessActivity`。结构化 manifest verifier 还会
校验权限 allowlist、`allowBackup=false`、非 debuggable、备份排除规则、唯一导出的产品
Activity，以及非导出的 `dataSync` endpoint service。
release APK 的 `assets/` 还会携带实际运行时依赖 protobuf-javalite 4.35.1 的
notice 与完整 BSD-3-Clause 文本；门禁会逐字比对仓库内经审查的版本。

`PairingKeystoreInstrumentationTest` 使用唯一测试 alias/preferences 验证真实
Android Keystore 的 P-256 identity 和 AES-GCM wrapping key，结束时清理测试状态，
不会读写产品 alias。常规 CI 只编译该 APK，不把“编译通过”冒充真机证据。仅在明确
选定可写测试设备后手动运行：

```text
tools/run-android-keystore-instrumentation.sh --serial <serial>
```

不要在 OEM 真机上用 `connectedDebugAndroidTest` 代替该 runner：Gradle 安装流程
可能先卸载产品包，再因厂商策略拒绝 test APK，导致 0 项测试却清空产品私有状态。
仓库 runner 先安装 test APK，成功后才运行 instrumentation，并且始终只卸载
`app.droidmatch.test`；安装被拒绝时产品包和数据保持不变。

debug APK 安装后，启动器里的 DroidMatch 图标会打开授权入口。真机 smoke 仍用 debug harness Activity 启动 Android 端 endpoint：

```text
adb shell am start -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity --ei port 39001
```

也可以用一键脚本完成安装、launcher 入口验证、debug harness 启动、ADB forward 和 `m1-smoke`；脚本会以 Swift release 配置构建并调用 Mac harness，debug/Onone 测量只可用于诊断，不能作为吞吐 gate 证据：

```text
tools/run-m1-device-smoke.sh --serial <serial>
```

传入 `--handshake-attempts 20 --min-handshake-passes 19 --list-path dm://media-images/` 可记录 handshake 稳定性和首个目录 listing 耗时；传入 `--list-expect-error-path <dm-path> --list-expect-error-code <code>` 可记录 listing 预期失败映射；传入 `--source-path <dm-path> --resume-check` 时，脚本会先做 intentional partial download，再用 `download --resume` 验证非 0 offset 恢复；传入 `--download-retry-on-transport-loss` 可让 resume/full download 在 transport close/timeout 后用 sidecar 自动重试一次，传入 `--download-retry-fault-check` 可注入本地 proxy 断线并要求 `recovered=true`；传入 `--upload-source <local-file> --upload-destination-path dm://app-sandbox/<name> --upload-resume-check` 时，脚本会先做 intentional partial upload，再用 `upload --resume` 验证 app-sandbox upload 恢复，destination 也可以换成 writable `dm://saf-.../<name>`；传入 `--upload-retry-on-transport-loss` 可让 app-sandbox/SAF resume/full upload 在已写入 sidecar 的边界自动重试一次，传入 `--upload-retry-fault-check` 可注入本地 proxy 断线并要求 `recovered=true`，app-sandbox 目标还可用 `--upload-retry-ack-loss-check` 丢弃首个 ACK 并验证 partial truncate/replay；fresh upload 的 destination 也可以是 `dm://media-images/<name>` / `dm://media-videos/<name>`；对 MediaStore fresh-only 目标可加 `--upload-resume-unsupported-check` 验证非 0 offset open 被拒绝；`--cleanup-upload-destination` 会清理 app-sandbox、直接 root SAF 单文件或 MediaStore upload 目标，嵌套 SAF token 目标仍需手动清理；100MiB 矩阵运行应加 `--chunk-size-bytes 1048576 --min-download-mib-per-second 20`，匹配的上传运行应加 `--min-upload-mib-per-second 20`。脚本会解析 harness 输出的 elapsed/throughput 并写入日志；同一组三台已选必测设备（Slot A、Slot C、Slot D/E 各一台）两方向都达到 20 MiB/s 前不得宣称通过。脚本默认会把脱敏结果写入 `fixtures/m1-runs/`。如果只想临时排查，可加 `--no-result-log`。

Slot A 的 current-tip 正式吞吐归档使用 `tools/run-m1-throughput-gate.sh`，而不是手工
拼接普通 smoke 参数。该 wrapper 强制 clean `origin/main` 完整 SHA、API 26–29、fresh
双向精确 100 MiB、请求/实际协商 1 MiB、双向 ≥20 MiB/s 与 raw ADB baseline；普通
runner 的私有输出不会被转发，并在远端 final/私有 staging partial、本地 transfer 文件和 owned
forward 都验证不存在后才发布版本化通过日志。普通 `--cleanup-upload-destination` 现在也
同时删除 app-sandbox final 与同一逻辑 destination 的 transfer-scoped 私有 partial。

这个 Activity 会保持屏幕唤醒并启动 `ForegroundConnectionService`。在部分国产 OEM 设备上，仅用后台前台服务启动后，app 线程可能进入 freezer，导致 ADB forward 连接进入 socket 队列但 Java `accept()` 不运行；debug harness Activity 是当前真机 smoke 的推荐启动方式。

当前 ADB 路径继续声明 `dataSync` foreground-service type：Android app 只接收 ADB forward 后的 loopback TCP，并没有持有 `connectedDevice` 在 Android 14+ 要求的 Bluetooth/UWB grant、网络状态权限或 `UsbManager.requestPermission()` 产生的 USB grant。为绕开 6 小时限制而声明并不满足前置条件的 `connectedDevice` 会在新系统上触发 `SecurityException`。Android 15 在 app 持续处于后台时会把所有 `dataSync` service 的总运行时间限制为每 24 小时 6 小时；达到限制后 `onTimeout()` 会关闭 endpoint 并停止 service。未来 AOA transport 真正通过 `UsbManager` 获得 accessory permission 时，再为该 transport 增加 `connectedDevice` type。

Mac 端通过 ADB forward 连接这个 endpoint 后，应跑 `m1-smoke` 验证同连接 handshake、heartbeat 和 control-plane RPC，再用 `list-dir` 取一个文件 logical path，并用 `download-cancel` / `download-pause` / `download` / `upload` 验证传输控制、多 chunk 下载、app-sandbox 上传、fresh MediaStore 上传和 fresh SAF 上传。
