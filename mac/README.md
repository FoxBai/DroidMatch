# DroidMatch Mac 端

这里是 DroidMatch Mac 端实现目录。

M1 最初策略（历史背景，产品 target 现已超过此阶段）：

- 先以命令行和最小验证壳打通协议，再把已验证能力装配进原生产品 UI。
- 验证 ADB 发现、授权、forward、握手和重连。
- 实现 `RpcEnvelope` 的 length-prefixed Protobuf 编解码。
- 跑通 `DeviceInfoRequest`、`ListDirRequest`、`OpenTransfer`、pause、cancel 和 resume。
- 收集 M1 需要的诊断日志和性能指标。

M0 规格已经收口，见 `docs/m0-closeout.md`、`docs/architecture.md` 和 `docs/protocol.md`。

当前仓库已经包含 SwiftUI `DroidMatch` 产品 target、普通/App Sandbox `.app`
组装，以及带 SHA-256 和只读挂载复核的本地 DMG。Slot C 普通与 sandbox 产品的
认证、浏览、双向传输、信任撤销和强退后恢复证据已归档；Developer ID 签名、公证
和持续发布仍未完成。Swift 测试与产品构建共用可写 module cache、Codex 外层 sandbox
适配和探针证明的 arm64e 回退；本地 release App 会把十个严格尺寸/格式校验的 PNG
rendition 打包为现代 ICNS，再由系统解码器反向验收，避开 macOS 26.5 会拒绝自身
合法 iconset 的 `iconutil` 编码回归。

`DroidMatchCore` 承载协议与资源 actor，原生界面状态边界位于独立 `DroidMatchPresentation` library，Keychain/bookmark 等平台适配位于 `DroidMatchAppSupport`。`DroidMatchApp` 已接通安全的 ADB 设备发现、动态 forward lease、SAS 首配/Keychain 重连认证、可信 Android 列表/撤销，以及认证后分页文件浏览、结构化诊断和按认证设备隔离的持久双向传输队列。撤销信任前会等待活动会话完全断开；若 Keychain 删除不能确认，可信设备行会保留并只显示固定脱敏提示。界面只接收进程内匿名 ID、名称和时间，不接收 pairing ID 或指纹。若 Hello-only 探测到 nonce-only 调试端点，产品会明确提示启用“安全 USB”，不会把端点模式误报为普通 transport failure。`--sandboxed` 构建会内置并单独签名 adb、携带 NOTICE 和最小 entitlement；该 bundle 已在本机只读发现两台设备，并在 Slot C 归档认证浏览、1 MiB 双向传输和强退后 4 GiB 上传恢复。

可恢复上传会在首次远端 open 前先写 App 自有 sidecar，并把精确
destination/transfer/expected-size 清理身份写入 schema-v2 队列。永久取消、失败任务
移除或会话关闭都不会直接遗忘 Android partial：队列先进入可恢复的 Cleaning Up，使用
新的已认证 client 幂等清理 App Sandbox/SAF 私有 partial，成功后才 settle/移除并释放
对应 bookmark；失败保持可见并可重试。暂停和普通会话挂起仍保留 partial 供恢复。

应用菜单以单实例 SwiftUI 窗口提供本地双语帮助，覆盖连接、配对、浏览、传输、权限排障和隐私边界。它显式替换 macOS 在没有 Help Book 时自动生成的无效“DroidMatch 帮助”动作；帮助视图只依赖静态本地化文案，不导入会话或 Keychain 类型，也不打开网络 URL。`tools/check-product-help.py` 与离线负例回归将该装配、无外链和无凭据依赖作为 M0 门禁。

文件、媒体、传输和诊断在没有 ready 会话时统一显示“连接并认证设备”的真实空态并返回设备页；文件与诊断不再沿用“产品会话边界/诊断尚未接通”的早期未来式占位文案。该空态只说明当前会话条件，不弱化已经实现的产品能力。

`ProductDisplayText` 是平台/对端可控名称的统一 UI-only 投影：NFC 归一化、折叠空白、移除 control/format/surrogate，默认限制 120 个 Unicode 标量（远端条目 240），真实截断会在该上限内显示省略号。ADB 型号/产品、配对名称、Keychain 可信设备、ready 会话、诊断及远端条目都在进入展示状态前使用该边界；动作仍使用独立匿名设备 ID、配对记录或 logical path。`DeviceSessionModel` 发布的配对确认值只有安全 Android 名称和六位 SAS，Core 的设备身份指纹不再进入 Published 状态。

诊断页可通过原生保存面板导出 schema v1 JSON 支持报告。编码器使用显式 allowlist，只包含 DroidMatch 版本/构建号、macOS 版本、快照新鲜度，以及已脱敏的设备概况、权限枚举、服务状态、错误数量与已知计数器；不存在主机名、用户名、硬件 UUID、locale、ADB serial、pairing ID、指纹、端口、文件名/路径、凭据、原始异常或原始日志字段。版本字符串还会经过 ASCII allowlist 和 120 字符上限。

文件浏览器的搜索与名称/修改时间/大小排序都重新提交完整 provider 查询，Android 在分页前完成过滤和排序；Mac 不会只重排当前页而制造跨页顺序错误。改变排序会清除选择态并使旧请求 generation 失效。Provider MIME 进入 Core listing domain 时会按最长 127 字节、受限 ASCII token 语法校验并统一小写；畸形可选值只降级为 `nil`，不会删除有效条目，也不会改变 path、capability 或动作准入。
列表和媒体网格都直接格式化 provider 返回的毫秒时间戳，并提供符合条目能力的原生右键菜单；下载、重命名和确认删除仍回送既有产品动作，不在 view 内复制权限判断或远端操作。
Mac 仅按 canonical path 本地化 DroidMatch 自有的 Images、Image Albums、Videos 和 App Sandbox 虚拟根；SAF 名称及所有用户文件名保持 provider 原文。禁止按英文名称猜测根类型，避免把同名用户目录错误翻译。
文件页头显示随导航历史保存/恢复的用户可读位置标题，不直接渲染 logical path；进入 opaque SAF/相册目录时，token 仍只用于 Core/Presentation 身份和授权，不成为普通产品文案。
远端名称另有 UI-only 安全表示：NFC 后移除控制符、双向覆盖/隔离符及高风险零宽格式符，并限制 240 字符。列表、网格、预览标题、重命名初值和本地下载建议名使用该表示；原始名称与 logical path 不变，远端选择/删除/传输不会因显示净化而改换身份。
选择模式可选择或清除所有“已加载且可操作”的项目；它不声称选择尚未分页的远端行。load-more 后新行保持未选，按钮重新变为“选择所有已加载项目”；目录快照变化会将 selection 与当前 path 集合求交，避免计数或批量动作携带已消失条目。93 行纯 `DirectoryBrowserSelectionState` 统一持有这些模式/path/capability/行序规则，并在批量下载部分受理时只移除已受理路径；它不持有 model、Task、panel 或 queue，三项直接测试覆盖该边界。父视图现为 682 行。

## 当前已实现

- `DirectoryMutationClient` / `DirectoryBrowserPolicy` / `DirectoryBrowserModel`：通过 async RPC 在 App Sandbox 或可写 SAF 当前目录创建直接子文件夹；Core 会在分配 request ID 和写 socket 前拒绝裸 `dm://` mutation endpoint。纯策略负责 direct-child 名称/路径、当前已加载条目的 mutation admission、批量稳定排序与有界错误分类，但不持有 client、Task、generation、token、缓存或 Published 状态。628 行 MainActor 模型继续唯一持有展示、listing generation、导航、派生 Task/预览/权限判断与按 path 应用 mutation 结果；132 行纯 `DirectoryBrowserThumbnailState` 独占缩略图 generation/FIFO/active-key/失败/缓存 transition，确保旧 generation 已准入请求排空前仍计入四项并发上限但不能发布，且不持有 client、Task、权限判断或 Published 值。三项直接测试覆盖这一并发不变量、可见性/失败准入和 64 项/8 MiB 双缓存上限。157 行 MainActor runner 另独占活跃远端 mutation Task 和操作身份且不持有刷新策略。目录导航只取消旧 listing 并清空旧 generation 尚未准入的缩略图队列，不取消已准入 mutation；同 path 完成刷新当前 query，其他 path 丢弃旧结果或错误。该次改进使 Swift 测试库存增至 437 项；错误状态只保留分类而不保留用户输入名称。
- `DirectoryMutationOperation` 把创建、重命名、单删和批删的有界失败类别映射为各自固定文案；创建/重命名若在提交时未被准入，会在仍可见的编辑 sheet 内反馈并清除父视图错误，已准入后的异步失败才由浏览器页展示。任何路径、条目名称或原始异常都不会进入这些说明。
- 同一 mutation 边界支持对可写普通文件/目录执行原地重命名，成功后原子刷新当前页；虚拟 root、跨目录移动和不安全名称在产品或 provider 边界被拒绝。
- 删除入口只出现在可写普通条目上，并显示文件/递归目录不同的破坏性确认文案；确认前不发 RPC，成功后刷新当前目录，错误状态不保留条目名称。
- SwiftUI 搜索框经过 250ms debounce 后发起新的目录查询；进入子目录会清空搜索，返回历史目录会恢复搜索条件，generation guard 拒绝旧结果。
- 选择模式仅接受当前可见的可读文件或可写普通条目；批量删除按 logical path 稳定排序逐项执行，目录保留 recursive 语义，中途失败会刷新目录并显示部分失败而不伪造事务回滚。
- 文件浏览区的原生选择面板与 Finder 拖放共享 `ProductUploadSelectionPolicy`：一次只接受最多 100 个名称按 NFC、大小写与宽度规范化后唯一的非符号链接 regular file URL，并重复目标/媒体扩展名校验。每项仍通过 `BookmarkingTransferQueueDataSource` 保存独立 security-scoped bookmark 并形成独立持久任务；若只有部分任务入队成功，产品会明确提示已接受项保留在“传输”中，不声称整批回滚。
- MediaStore 图片/视频目录默认使用自适应原生网格并可切换回信息密度更高的列表；两种布局都只为可见项按需请求 96 px 缩略图。每个浏览器的后台队列最多同时执行 4 项，缓存同时受 64 项和 8 MiB 约束；切换分类或离开界面会清空尚未准入的派生工作、预览和缓存，已准入请求只排空而不再发布。点击后的最长边 512 px 原生 sheet 预览不排入后台队列，因此可成为当前浏览器第 5 个 control request。Core 拒绝非媒体路径、空值/非十进制/溢出的 MediaStore item ID、越界尺寸、超过 512 KiB 的响应和异常 MIME/尺寸。listing 分页与预览/缩略图有独立有效性，load-more 不会把正在完成的预览留在永久 loading 状态。预览仍是系统生成的有界 derivative，不经控制 RPC 读取完整原文件。
- 图片相册根与相册内部都使用媒体网格；根目录只为可见相册懒加载 Android 选取的最新图片封面，点击目录则进入相册而不是打开图片预览。相册条目由 Android 返回，Mac 不合成或解析 bucket token。相册内媒体仍使用平面图片视图的唯一 logical path，因此选择、缩略图缓存、预览和下载不会产生双重身份。
- 侧栏提供独立“媒体”入口；Files 从产品根列表隐藏 Images、Image Albums、Videos，Media 是唯一的产品媒体浏览与上传入口，因此通用文件浏览不会保留未经重新检查的媒体名称，也不会绕过 fresh-only 披露。`MediaLibraryModel` 先读取认证后的实时 root capability，再为图片、相册、视频各持有一个独立 `DirectoryBrowserModel`，因此切换分类或离开媒体页不会破坏各自分页与导航 query。显式重新检查/重新进入会先 fail closed 清除所有已加载媒体名称和派生缓存，再在 root catalog 通过后用原 query 重列；这覆盖 Android 14 仅选照片集合变化但 root 仍可读的情况。child 返回权限错误时按创建时捕获的分类进入稳定授权态，不自动形成 roots/list 循环。读取和写入能力仍独立，只写的图片/视频 root 也可从权限空态通过同一批量面板提交上传；产品用精确媒体扩展名过滤并复核面板/拖放，队列和 Android 在创建 MediaStore row 前再次拒绝未知或错分类类型，并明确披露 MediaStore 上传不可暂停/续传。
- 多选下载与批量删除分别按 `canRead`/`canWrite` 启用；下载面板完成后由 AppSupport 纯策略重新核对精确 query/row/授权/readiness，并在任何 bookmark 或 scheduler 副作用前拒绝非本地目标 URL、已存在目标及 canonical/case/width 重名。每项仍注册父目录 bookmark 并形成独立可恢复任务。提交阶段如果只有部分任务被持久队列接受，界面会区分“全部未开始”和“部分已开始”，并只保留未接受文件的选中状态，要求重试前检查“传输”队列。

- `AdbClient`：选择 adb 路径、解析 `adb devices -l`、创建/list/remove adb forward。
- `AdbDeviceDiscovery` / `DeviceDiscoveryModel`：在私有队列执行有 5 秒上限的阻塞 ADB listing；非法配置 timeout 会在启动 ADB 前归一为稳定 `timedOut`。Core 内把 serial 映射为进程内 UUID，再以可取消、可防旧响应覆盖、失败时标记 stale 的 MainActor 状态交给产品 UI。商品名解析器只接收 model/device/product；独立的本地审核别名表要求精确型号/设备匹配和无凭据 HTTPS 厂商来源，按 Mac 首选语言执行完整标签→地区→文字→基础语言回退，重复或无效记录 fail closed，且只缓存官方 canonical name，避免语言切换被旧缓存锁死。704SH 可离线解析为夏普仅有的日文「シンプルスマホ4」；其余未命中项通过无 Cookie、拒绝重定向的临时会话流式读取唯一固定的 Google Play 完整公开目录。独立 catalog-loader actor 执行 8 MiB、格式、行/字段和唯一匹配校验并构建进程内索引；resolver actor 最多保留 64 个待查参数，只做有界查表/发布，所以本轮发现不会等待网络或 CSV 解析。匹配及缓存键使用未被 UI 截断的完整 512-scalar 有界参数，本地最多保存 512 个以参数元组 SHA-256 为键的安全商品名，不发送 serial/逐设备搜索词。前台活跃的 App shell 每 1 秒触发一次非重入自动刷新，查询进行中会跳过 tick，以支持 USB 插入后无需手动操作即可出现；App 进入后台/非活跃或 view 消失时停止未来轮询，已开始的安全查询仍可收敛。同一 actor 按匿名 UUID 创建动态 `tcp:0 → tcp:39001` lease，私下保存 serial/端口清理所有权，同设备并发 preparation 会被拒绝；取消、异常端口、失败或断开时幂等移除 forward，字段不匹配的 release 也不会提前丢失后续精确清理所需的所有权。
- Google 商品名缓存以来源和最近核验时间进入 v3；默认 24 小时内直接离线返回，只有来源已知的过期 v3 记录采用 stale-while-revalidate，先返回安全旧名称再后台刷新完整清单。来源不明的 v2 旧记录会迁移为未核验状态，但在完整目录或当前审核别名确认前不显示；畸形 v3 条目会在 resolver 初始化时立即从本地清除。有效新清单会覆盖改名并删除不再唯一匹配的旧项；刷新失败只保留已核验过的旧值并受同一节流约束。审核别名仍由当前内置表优先决定，已移除的别名来源不会作为永久缓存复活。
- `DeviceCard` 以共享常量暴露固定 `app.droidmatch.discovery-device-card` Accessibility identifier，商品名作为主标题，去重后的 model/product 作为次行技术信息，并生成明确的 `ADB`、live/stale 状态与 Connect/Reconnect label。Accessibility label 继续保留每个安全的精确 component，因此正式 USB 插入 runner 可在新增商品名后继续匹配原型号；它只匹配该 identifier 和精确逗号分隔 component，不扫描任意按钮文本。运行 App 还必须是调用方指定、bundle checker 通过、内嵌 clean current-main SHA 的唯一 release bundle。
- 商品名先经同一凭据 UTF-8 字节上限投影，再随匿名 forward lease 进入 Core 会话，并由认证标题、新配对记录和可信设备行共同使用；它不参与指纹选择、SAS 或 proof。新配对随同一次原有写入保存该安全名称；旧配对认证成功后只在共享 actor 内建立进程期 pairing-ID→名称覆盖，ready generation 在该 actor hop 后再次校验。可信列表下一次无机密刷新以相同匿名 UI ID 展示覆盖名，不新增钥匙串读取/写入；撤销成功同时清除覆盖并留下进程期 tombstone，拒绝迟到认证任务重新写回。旧记录重启后会先显示原名，直至再次成功认证。
- `TrustedDevicesModel`：可信设备元数据的 Keychain 加载最多显示 5 秒忙状态；display-only 查询通过禁止交互的 `LAContext` 明确不拉起认证窗口，若 securityd 长时间不返回，界面先收敛为“暂时不可用”，同一底层请求不会因 view task/刷新重复堆积。界面会区分“系统请求仍未返回”与“已经可以重试”：前者说明该检查不会弹窗并提示重开 App，后者才显示可执行的就地“重试”，不会把单飞拒绝伪装成恢复动作。没有中途 mutation 时，迟到的成功结果仍会原子替换快照并自动恢复；撤销会先使既有列表 generation 失效，防止旧快照重新发布已移除设备，同时让旧请求正常退场后重新开放刷新。删除失败或 false 会保留行、标记快照不可用并显示固定脱敏提示；设备页刷新同时重试发现和已完成失败的信任列表查询。只有用户主动连接后的凭据选择会读取配对密钥并允许系统按需认证。连接卡和本地帮助会把可能出现的 macOS 钥匙串提示解释为“授权读取已保存的设备配对密钥”，明确它不是 Apple 签名请求且 DroidMatch 没有密码输入框；读取失败先提供系统对话框允许后重试的路径，再建议移除信任并重新配对。
- `ProductDeviceSessionCoordinator` / `DeviceSessionModel`：Core actor 用 Hello-only 新连接读取身份选择器，按精确指纹选择 Keychain 记录，再以第二条新连接完成双向 proof；没有记录时通过 Android 可见窗口和 Mac 六位 SAS sheet 首配。Presentation 只发布经 `ProductDisplayText` 投影的 Android 名称与 SAS，不发布设备身份指纹。认证 control/browser client 每 10 秒 heartbeat；timeout、transport/remote failure 或回显不一致会先按 gate → queue → client → forward 拆除当前会话，再通过会话级缓存事件让 MainActor 离开 `.ready`、清空 browser/diagnostics/queue/session info，并以稳定 `connectionUnavailable` 失败保留所选设备供显式重连。认证后的 event/browser/transfer queue 组装采用全有或全无事务：当前 generation 的任一依赖失败（包括非调用方取消产生的 `CancellationError`）都会复用唯一、可等待的 teardown，完整断开后才发布稳定失败；显式断开或替换仍保持静默，新的连接必须等待旧 teardown，且不会被迟到清理命中。transfer retry-client gate 以真实 TCP/配对认证和确定性失效竞态验证，失效前拒绝新连接，连接期间失效则先关闭新 socket 再取消，避免旧队列复活。Hello-only 如果收到 nonce-only 调试端点的 `correlated` 状态，会归类为 `secureEndpointRequired`，界面明确提示关闭调试 USB、启用产品“安全 USB”；显式断开只结束旧 observer，不显示失败；generation 拒绝旧操作，Presentation 不持有 serial、端口、密钥或原始异常。
- `ProductDeviceDiagnostics` / `DeviceDiagnosticsModel`：在认证会话上并发读取 device-info 与 diagnostics，丢弃 Android device ID、事件/错误原文、线程名、任意 counter key 和畸形值；只把 allowlist 权限/计数器、粗粒度服务状态、错误数量、存储、电池和系统版本交给 MainActor。刷新失败保留明确标记为 stale 的上次健康快照。
- `FrameCodec` / `FrameReader`：4 MiB 上限的 length-prefixed frame 编解码。
- `TransportError`：异步 transport 与恢复策略共享的稳定错误分类；旧同步 TCP client/session 已删除。
- `AsyncFramedTcpSession` / `AsyncTimeoutPolicy`：面向产品层的 actor 化非阻塞 transport 边界；连接会在首次使用时永久选择 FIFO round-trip 或 multiplexed I/O，禁止混用。multiplexed 模式保持 send FIFO，但允许 RPC 层唯一 reader 独立等待；空闲 reader 不套用 request timeout，连接关闭会唤醒全部排队 I/O。Network.framework callback/timeout/cancellation 复用 RPC waiter 的 lock-backed one-shot，保留首个结果优先语义，不再维护另一套带 trapping 状态的 continuation gate。统一 timeout policy 在任何连接/子进程副作用前拒绝非正数、NaN 与无穷大，并在整数或 `DispatchTime` 转换前饱和超大有限值；harness 的 `--timeout-seconds` 也会拒绝缺值和非法值。
- Swift 状态边界继续 fail closed：RPC 协商结果直接绑定 `ready` state；process-local persistence reload 返回稳定 `ioFailure`；scheduler admission 以 typed throws 让兼容 `submit()` 的错误投影在编译期可穷尽。三处都不再保留不可达的进程 trap，也不改变 wire 或 retry policy。
- `RpcEnvelopeCodec`：同步 harness 与 async 产品客户端共享的 envelope 构造/校验逻辑；统一检查 `frame_version`、可选 payload CRC、request ID、frame kind 和 payload type。
- `AsyncRpcControlClient` / `AsyncRpcMultiplexer`：要求先完成 Hello；注入 `PairingCredentials` 时继续完成双向 proof 并拒绝降级。协商结果直接绑定在 `ready` state 内，因此类型上不存在 ready 但缺失 handshake cache 的组合，重复 `handshake()` 也不会写第二个 Hello。唯一 reader 按 request ID 路由并发控制响应，按 request/stream ID 路由最多两条活跃传输；同 actor 的 `AsyncRpcMultiplexerInboundRouting` 只分组入站解析、waiter 唤醒和 route mutation，不复制状态或拥有第二 reader/socket。所有 multiplexed write 先进入同一 FIFO gate，download ACK/upload chunk 在真正 send admission 前重新校验 route/window 与首个终态错误，避免 teardown 后迟到发送，并为恢复策略保留最初的可重试 transport 或 typed remote 错误。`AsyncRpcRoutingState` 只保存 route record、request ID 轮转和纯验证，`AsyncRpcTransferFrames` 只负责 open/chunk/ACK protobuf 构造，二者都不拥有 actor/task/socket。公开 `AsyncDownloadTransfer` / `AsyncUploadTransfer` handle，下载使用 4 chunk / 2MiB 有界队列，上传 handle 当前逐 chunk 等 ACK。callback/async 共用 one-shot 会在锁内原子认领唯一消费者；第二次 wait 返回 typed 内部状态错误，不再覆盖原 continuation 形成永久挂起，也不在结果消费后触发 precondition crash。process-local scheduler persistence reload 也返回稳定 `ioFailure`，不再终止进程。control/open/ACK deadline、transport failure 或协议错位会关闭 session。取消发生在 send admission 之前时只移除本地 waiter；已准入的 mutation、传输 open/ACK 或其他有副作用控制请求被直接 Swift Task 取消时，会关闭结果歧义的 session；已准入的只读 heartbeat、device-info、list、diagnostics 和 thumbnail 则只让调用者收到取消，Core 保留 request ID/deadline，并在原期限内校验、排空迟到响应。迟到的错误类型、嵌套 protobuf 或 envelope 仍会关闭 session。真实本地 TCP 测试覆盖 control、download/upload open 与 upload ACK 无响应，统一 timeout policy 会在 `Double` 转整数或 `DispatchTime` 前拒绝/饱和边界值。单次 download `nextChunk` 等待取消不会偷走 reader，remote application error 也保持 session 可用。一项 one-shot 回归曾把库存带到 438，persistence reload 回归带到 439；本轮六项 timeout/发现回归使当时 Swift 测试库存为 445 项；诊断导出边界的一项恶意构造快照回归使当时库存为 446 项。
- `TransferResumeRecords` / `AsyncTransferResumeStore`：把 CLI 与产品共用的 download/upload sidecar schema 收口到 Core；保留历史 camelCase JSON 兼容，所有阻塞文件操作在私有串行队列执行。load/save/remove 会从根目录逐 component 以 `openat(..., O_NOFOLLOW)` 固定 parent（仅解析 macOS 固定的 `/var`、`/tmp`、`/etc` 系统别名），并以单链接 `0600` 普通文件、完整 stat、目录项/描述符身份与 parent 重绑定复核拒绝其他 symlink、directory、FIFO、hard link、宽松权限和替换竞态。保存使用固定 `.<name>.pending`：文件同步后，目标缺失走 `RENAME_EXCL`，已有目标走 `RENAME_SWAP` 并双向复核；删除使用固定 `.<name>.removing`，复核后才 unlink。目录 `fsync` 是强制步骤；任何发布、unlink 或同步失败都必须证明安全回滚，否则返回 `commitUncertain` 并留下可发现 recovery node。每个已使用的固定 parent 永久保留一个不含目标名或路径的零字节 `0600` `.droidmatch-private-atomic-lock`；read/save/remove 全事务对其取得独占 `flock`，并在加锁后复核 owner、普通文件、单链接、权限和目录名/FD inode 身份，从而同时串行同进程独立 FD 与协作进程。锁节点永不 unlink，避免同名新 inode 分裂锁；不安全节点会在读取恢复数据前 fail closed。该 advisory 边界仍不抵抗主动绕锁的同 UID 进程，也不宣称通用断电耐久性。
- `TransferWireMetadata`：Android 只按逻辑 `destination_path` 授权上传，因此产品和 harness 的 inactive-side `source_path` 统一使用 `mac-local-upload`；真实 POSIX 路径只留在 Mac sidecar 做恢复身份校验。普通成功输出也只显示 `<local-file>` / `<local-partial>` / `<local-sidecar>`；直接 harness 诊断会把远端路径、文件名、provider message 和异常原文限制为脱敏标签。
- `DroidMatchHarness/main.swift` / `HarnessTransferCommands.swift` / `HarnessUploadCommands.swift`：前者负责 CLI 分派、ADB/control probes、帮助与共享解析，后两者分别集中 download 与 upload/error-boundary 命令；三者都只消费 Core，不另建产品架构。
- `AsyncDownloadCoordinator`：通过注入的 client factory 在每次尝试创建并认证新连接，持久化 Android 接受的源指纹，按实际 partial 长度用同一 transfer ID 重开，并以可取消指数退避自动恢复。产品 executor 在进入 coordinator 前持有 security scope、父目录 FD，以及进程内 registry 与跨进程 advisory `flock` 共同组成的 download destination lease；该 lease 同时预留 final、`.droidmatch-part`、sidecar 及其 `.pending`/`.removing`、commit marker 与 replaced entry，并把父目录 device/inode 传给 writer 复核。跨进程层在已固定父目录中使用私有 `0700` `.droidmatch-download-locks`、`0600` `.droidmatch-download-lock-root` identity anchor 和不含原文件名的 SHA-256 命名空锁文件；每个此前未见的目标最多永久新增七个零字节 inode，这些空文件会持久复用而不在解锁时删除，避免用同名新 inode 分裂锁。任意用户/卷 ancestor symlink、不安全锁节点、并发同物理命名空间或 lease 后 parent 重绑都会在修改 checkpoint 前 fail closed。fresh 尝试随后打开并 `flock` partial，安全移除旧 sidecar，再在已锁定 FD 上执行显式 `resetFresh`，全部成功后才创建连接。成功后清理 sidecar，损坏或孤立 checkpoint 则显式失败。哈希名只是避免直接暴露名称，不是加密；advisory lock 也不抵抗主动忽略它的同 UID 进程。
- `AsyncUploadFileSource` / `AsyncUploadCoordinator`：本次尝试只打开并持续持有一个 `O_NOFOLLOW` regular-file descriptor；v2 checkpoint 记录 size、纳秒 mtime、纳秒 ctime、filesystem 与 inode，每次 I/O 前后同时校验 descriptor 和当前 path。scheduler restore 尚未持有 bookmark lease，只检查 v2 结构、路径和身份字段存在；AppSupport 授予 lease 后，coordinator 会精确 snapshot 并在 client factory 前拒绝 stale source。即使替换文件保持同大小与同毫秒 mtime 也会 fail closed；旧非零 v1 checkpoint 同样在 client factory 前被拒绝。协调器持续填充 4 chunk / 2MiB 窗口，按每个有序 ACK 原子推进 sidecar，app-sandbox/SAF 断线后用同一 transfer ID 和最后 ACK offset 重开。MediaStore 保持 fresh-only。
- `AsyncUploadFileSender` / `AsyncMixedTransferSmokeClient`：把稳定文件读取到 4 chunk / 2MiB 窗口的 pump 从 coordinator 中提取复用；mixed smoke 在独占 async session 上先 open 下载/上传，在下载尚未 ACK、上传尚未发 chunk 时要求 heartbeat 往返，再并发完成原子接收和窗口上传，最后复验本地上传源。inactive-side upload source 固定为 `mac-local-upload`，不会把本机路径或真实文件名发送到远端诊断。
- `DirectoryListing` / `ProductMimeType` / `DirectoryBrowserPresentationTypes` / `DirectoryBrowserModel`：Core 把 protobuf listing 转成 typed query/page/entry/error，原样回传 opaque token，并校验内嵌错误、row identity、kind、token 防环及可选 MIME；MIME 只接受最长 127 字节的受限 ASCII 类型或 DroidMatch 自有标签，统一小写，畸形值降级为未知。独立展示值边界负责稳定 phase/failure/item 与 UI-only 文件名净化，原始名称和 canonical identity 不变。MainActor 模型串行执行 load/refresh/load-more，切换 path 时拒绝旧响应，刷新失败保留 stale rows，翻页失败保留 token 可重试，跨页 path 重复只展示一次；设备文件名不进入失败状态或日志。
- `AsyncTransferSchedulerAdmission` / `DownloadDestinationReservation` / `AtomicDownloadWriter`：同一 scheduler 把 final、partial、sidecar、sidecar 的固定 `.pending`/`.removing`，以及 `.droidmatch-commit`/`.droidmatch-replaced` 七类 entry 当作一个命名空间；任意交集只允许一个非终态 download，恢复时所有冲突行都转为 `interrupted`。产品执行期另以父目录 device/inode 和卷大小写语义规范化的 entry 集合做进程内 registry，并为七个派生名按固定顺序取得跨进程 advisory 锁，覆盖不同 provider、scheduler 与协作中的 DroidMatch 进程；security scope、目录 FD 和两层锁都持有到 coordinator 结束。私有 lock root/anchor 必须保持预期 inode、owner 与 `0700`/`0600` 权限，空锁文件必须是单链接 `0600` 普通文件；未知节点不会被递归删除。任意用户或卷 ancestor symlink 会拒绝，但固定 `/var`、`/tmp`、`/etc` 系统别名先映射到 `/private` 后再逐 component no-follow 打开。无状态 `AtomicDownloadPartialFile` 负责 no-follow 目录/partial 打开、单链接普通文件校验、非阻塞独占 `flock` 与 descriptor/name inode 对账，且不保留 descriptor 或 writer 状态；`AtomicDownloadWriter` 持有返回的 FD 与事务状态直到 final publication，fresh 仅在锁定 FD 上 `ftruncate`。提交前创建、设为 `0600` 并同步固定 commit marker；目标缺失走 `RENAME_EXCL`，目标存在走 `RENAME_SWAP`，旧目标随即移到固定 replaced entry。marker 与旧目标一直保留到 sidecar 删除成功；若清理或 finalize 失败，先恢复旧目标与 candidate partial，在同一个 marker 仍存在时重新持久化 sidecar，最后才退役 marker。checkpoint 恢复失败会保留 marker，使重启明确恢复为 `interrupted`。无法证明回滚才返回不自动重试的 `commitUncertain`；崩溃遗留任一 recovery entry 会阻止自动 resume。所需目录 `fsync` 不是 best effort，但该边界仍不宣称完整断电耐久性，也不抵抗同 UID 恶意进程忽略 advisory 锁。
- `AsyncTransferProgress` / `AsyncTransferRateEstimator` / `AsyncTransferScheduler` / `TransferQueuePersistenceStore`：默认是进程内 FIFO 产品队列，最多同时运行两项；可显式通过版本化原子 manifest 跨 scheduler 重建。私有 manifest 文件名使用认证后设备指纹派生的域分离路由摘要，不再直接嵌入原始稳定指纹；旧文件名仅在新位置不存在时同目录原子无覆盖迁移，冲突、符号链接和非普通文件均保留现场并 fail closed。该摘要是匿名路由而非加密秘密。不可信 manifest 限制为最多 10,000 个 job、10,000 次配置重试、一天退避和累计 1,000,000 次 attempt；queued/普通 paused 必须预留完整重试空间，可恢复 paused 仅接受已消费 attempt 或确已发布 retry 的基数，active 无余量转 interrupted。retry/resume/terminal 使用同一 checked 计算；retry 写盘失败会回滚 attempt mutation、取消 executor 并关闭持久执行。manifest 与运行时记录的双向规范化位于独立 `AsyncTransferSchedulerPersistence` 纯边界；shutdown/suspension 的 job/queue 状态决策位于不持有 Task、timer、store 或 continuation 的 `AsyncTransferSchedulerSessionEndPolicy`；retry attempt、写盘前回滚、单调稳定总量进度与当前 rate generation 校验位于 120 行纯 `AsyncTransferSchedulerExecutionPolicy`；executor 退场对账位于只修改传入 record 并返回 paused/interrupted/terminal resolution 的纯 `AsyncTransferSchedulerCompletionPolicy`；终态 outcome、完成 waiter 和 buffering-newest 快照 observer 位于 actor 隔离的 `AsyncTransferSchedulerConsumerState`。scheduler actor 现为 699 行，继续独占存活 task/records/queue，并负责在首次挂起前执行 policy 返回的显式 action、取消执行任务、停止 rate timer、写盘、广播与等待退场。会话挂起先发布保守的 `interrupted`，但对仍在退场的不可暂停 executor 延迟 settle；普通退场保持 interrupted，只有已经越过本地回滚边界的真实 download 成功才改为 completed。损坏 manifest 修复后的产品重试会在同一个 App 操作门内重新加载 bookmark store、读取只读 restore plan、取得全部 checkpoint security scopes 与 download directory contexts、规范化持久队列并完成 readiness 后才激活 executor；任何一步失败都保持 held/reload-required，可再次重试且不会把部分恢复写成可执行状态。快照除 queued/running/retrying/pausing/paused/completed/failed/cancelled/interrupted、attempt/backoff 外，还提供 `canPause` / `canResume` / `canCancel` / `canRemove`、跨重试单调的 `confirmedBytes` / `totalBytes` / 完成比例，以及基于单调 uptime、两秒时间加权窗口的 `recentBytesPerSecond`。取消中的 executor 真正退场前 `canRemove` 保持 false。下载只在 partial 写入并 ACK 后推进，上传只在 ACK（可恢复目标还要求 sidecar 保存）后推进；最终完成值还要求各自的本地校验和 checkpoint 清理。排队任务可直接挂起；运行中的下载或 app-sandbox/SAF 上传只在持久断点建立且未到 100% 时可暂停，关闭该任务的独占 coordinator session 后保留 checkpoint，并以同一 job/transfer ID、`resume: true` 放回 FIFO 队尾。MediaStore 运行中暂停被明确拒绝；持久模式也会在 executor 启动前先写盘。restore 只有在 checkpoint 结构/路径有效、total 已知且无冲突、并满足 `0 <= offset < total` 时才把 active download 或可恢复 upload 置为 paused；`offset == total`、`0 / 0`、unknown/conflicting total 和其他不可信状态都转为禁止自动重放的 `interrupted`。upload restore 因尚未持有 bookmark lease 只校验 v2 结构/路径，lease 建立后由 coordinator 在 client factory 前精确校验源 snapshot。重试与暂停会清空速率窗口，运行态两秒无新确认会自动发布 nil，进入终态则冻结当时仍有效的样本。调度器只组合 coordinator，不解析协议。
- `DroidMatchPresentation` / `TransferQueueModel`：独立于 Core 的 macOS 13+ Combine 边界，在 MainActor 上把 buffering-newest scheduler 快照映射成稳定有序的展示项，并发布脱敏的持久化健康状态。订阅显式、幂等且可重启；stop 保留最后快照，旧 generation 不能覆盖新订阅；动作不做乐观改写，等待 scheduler 权威更新。单文件、批量上传与批量下载共用 model-wide 单飞准入；登记期间的并发调用在到达 bookmark/manifest/scheduler 数据源前返回，文件与媒体的搜索、选择、行操作、导航和分类切换会一致进入 busy，迟到的批量完成只从当前选择移除本次已接受项；已登记任务仍由 scheduler 并发执行。持久化失效/恢复、批量清理和新提交彼此互斥；行、网格、预览、工具栏、拖放和媒体 upload-only 入口会在原生面板前禁用传输并显示就地恢复告警，浏览与远端 mutation 不受影响。下载提交只接受 `dm://` 源和本地 file URL；展示项只包含经 `ProductDisplayText` 净化的有界本地 basename 和白名单化失败分类，不再发布未使用的远端逻辑路径，也不携带可能含 POSIX 路径的原始 failure description。队列行与 opt-in 系统通知共用该安全 basename，未知或追加内容的失败标签不会形成分类。同一 job 的 UI 动作在等待权威结果时不会重复准入；批量清理只按当前顺序移除 `completed && canRemove` 行，失败、取消、interrupted 和尚未退场的行保留，逐项持久化失败会以精确计数披露而非乐观隐藏。
- 产品文件/媒体传输入口以及传输页的 pause/resume/cancel/remove/clear 会等待 `TransferQueueModel` 的首次权威持久化状态读取，避免把初始 `.disabled` 占位值误作健康；恢复失败或进行中也会禁用这些 mutation，队列页显示红色/橙色权威状态，竞态拒绝只给出固定脱敏提示。非持久 scheduler 的程序化提交语义不因此改变。
- `AsyncTransferFailureLabel` / `AsyncTransferFailureCode`：scheduler 在 retry/terminal 边界把 coordinator、transport 和平台异常压缩成有限稳定标签；远端错误只保留协议 `ErrorCode`，不把本地路径、SAF document ID、provider message 或原始异常文本放入 Core 快照或完成结果。类型化视图只接受 Core 自身生成的精确标签；未知或带附加文本的值返回 nil。中文：队列错误标签只保留可操作的稳定类别，原始路径和 provider 细节不会穿过 scheduler 边界。
- `DroidMatchApp`：SwiftUI `NavigationSplitView` 产品壳，中英文设备总览可直接展示真实 ADB 发现结果，但不显示 serial；文件页以原生目录面板选择下载目标、以 `NSOpenPanel` 一次选择 1–100 个上传源，并只在认证能力和当前目录都允许写入时开放上传。文件父视图继续独占搜索、选择、原生面板和队列提交；列表/网格渲染只接收无状态 state/actions 快照，面板完成与下载规划由 AppSupport 纯策略 fail closed 复核。媒体页只组合分类选择、权限恢复和同一安全上传边界；`ProductFileBrowserChrome` 只承载认证标题、空态/错误/拖放视觉、编辑 sheet 与有界提交失败文案，工具栏则保持独立无状态 action/state 组件。未认证、空态、页头、提示条、统计/诊断卡和已有文字名称的缩略图/预览会把纯装饰图像从无障碍树隐藏；统计值成组朗读，文件/媒体选择与排序公开本地化“已选择/未选择”，图标按钮及传输方向也有明确名称。正式 Settings scene 可持久设置媒体目录默认布局，并显式选择是否请求 macOS 传输通知权限。通知仅针对观察期间完成/失败/中断的任务，使用脱敏 basename；已有历史、取消与重复终态不提醒。传输页展示双向真实进度、速率和暂停/继续/取消/移除动作，提供只清除已完全收尾成功项的批量历史清理，并为 retrying/failed/interrupted 行显示固定、本地化且不含原始异常的下一步。
- `HandshakeSmokeClient`：为每次连接生成 32 字节随机 nonce，可携带 pairing ID，并校验 `ServerHello` 的 request ID、协议、transport、nonce 回显、server nonce 与认证状态。
- `SessionAuthenticator`：配对会话认证的纯密码学内核，按固定 big-endian transcript 生成 SHA-256、role-separated HMAC proof 和 HKDF session key；Swift/Java 共用同一 fixture，现已接入 async paired reconnect 状态机。
- `PairingAuthenticator`：首次配对的 CryptoKit P-256 ECDH、canonical transcript、两路 HKDF、无偏六位 SAS 和三阶段 confirmation；与 Java 共用固定测试向量。
- `AsyncPairingClient`：一次性执行 start/confirm/finalize，先验证 Android 稳定设备身份签名，再把 SAS 和设备指纹交给异步审批闭包；仅在双向 confirmation 成功后临时写 Keychain，finalize 失败会撤销。产品层已接入真实 Mac SAS sheet，transport timeout 长于 Android 审批等待。
- `KeychainPairingCredentialStore`：使用禁止同步的 generic-password item 保存完整 pairing record，并把无密钥的选择/展示元数据作为版本化 `kSecAttrGeneric` 属性；可信设备 UI 使用独立 display-only 列表，当前记录校验 envelope，旧记录只校验 account、label 与 Keychain 时间，普通启动和刷新均不读取密码数据。明确重连时，当前记录只加载指纹匹配项，认证成功不再为最近使用信息改写承载机密的记录；首次配对把刚保存的 Core 凭据直接交给随后的认证 proof，不会从 Keychain 读回来。由于 macOS 会拒绝 generic-password 的 `MatchLimitAll + ReturnData`，旧记录使用逐 account 的 `MatchLimitOne` 查询，但复用一个 `LAContext`，成功解码后一次性回填全部 selector，使后续连接回到单记录路径。同一认证 generation 的传输 gate 接管刚完成 proof 的 Core 凭据，不再为了 scheduler 第二次读取 Keychain；接管后 coordinator 立即释放自己的引用，断开/替换/keepalive 失败会走同一 gate 失效与资源 teardown，凭据不进入 Presentation、日志、诊断或持久化。同一 pairing ID 绑定另一设备指纹及畸形/账号不匹配元数据均 fail closed。普通单元/门禁使用注入后端，真实登录钥匙串集成测试仅在显式设置 `DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST=1` 时运行。本地 ad-hoc App 重建后代码身份变化仍可能令 macOS 再次询问；这与 Developer ID 发布签名/公证是独立事项，后者继续按当前决定暂缓。
- `M1SmokeClient`：通过 `AsyncFramedTcpSession` / `AsyncRpcControlClient` 在同一连接上连续跑 handshake、heartbeat、device info、`dm://roots/` root listing 和 diagnostics；真实本地 TCP 测试覆盖成功顺序，并用可恢复远端错误证明失败时由 wrapper 关闭独占 session；`m1-smoke` 的命令名、能力协商与成功输出保持兼容。
- `TransferResults` / `RpcControlClientError`：async 下载/上传结果与协议校验错误；旧同步 `RpcControlClient` 已删除。
- `droidmatch-harness`：提供 adb/path/devices/frame/forward/framed-echo/handshake-smoke/m1-smoke/dual-download-smoke/mixed-transfer-smoke/list-dir/list-dir-all/list-dir-expect-error/download-once/download-cancel/download-pause/download/upload 命令。`list-dir-all` 原样回传 opaque cursor，拒绝跨页 identity/cursor 循环，且只输出聚合计数。

Swift protobuf codegen 已接入，`m1-smoke` 是当前 Android endpoint 的正式 M1 control-plane 联通命令，会在同一连接内验证 handshake、heartbeat、device info、root listing 和 diagnostics。`handshake-smoke` 可在 async FIFO session 上单独排查 hello 阶段，并把 `pairingRequired` 作为合法诊断结果返回而不进入认证；`framed-echo` 同样走 async FIFO session，保留给本地 echo server 或旧 placeholder endpoint 做 frame 层排查。

全部产品和 CLI 网络路径都已迁到真正非阻塞的 async session，包括完整/部分上传、逐 ACK sidecar、resume、ACK-loss 重放与 transport retry；旧同步 client 已无调用。async pause 不会 ACK 已收到的首块，返回 offset 始终停在最后确认边界。SwiftUI 产品代码不在 MainActor 调用同步 session，也不使用 `Task.detached` 包一层伪异步；产品会话、真实目录页和结构化诊断页均通过 Core/Presentation 边界。普通与 sandbox release bundle 的结构、签名和精确 entitlement 已自动验证；sandbox 产品认证/文件传输与 mixed 真机证据已在 Slot C 归档，Developer ID 签名和公证仍未验证。

## 命令

本地验证：

```text
bash tools/run-swift-tests.sh
bash tools/run-swift-tests.sh --filter 'lockedValueUnlocksAfterThrowingUpdate'
swift run --package-path mac droidmatch-harness frame-self-test
swift run --package-path mac droidmatch-harness devices
```

不带 filter 的完整 gate 会先读取 SwiftPM 的唯一测试清单，再按默认最多 20 项拆成精确
转义分片，并逐片核对实际执行数；这既限制本地 TCP fixture 的瞬时并发，也不会使用
Swift Testing 1902 会停滞的实验全局并发宽度。`DROIDMATCH_SWIFT_TEST_SHARD_SIZE`
可在 1–20 之间缩小分片。`--filter <regex>` 只用于本地迭代：它保留仓库 runner
的 Swift Testing framework、target 和 scratch fallback，并把正则原样交给
`swift test`。提交或交接前仍必须运行不带 filter 的完整 Swift gate；
`check-m1-skeleton.sh` 也始终走同一全量分片路径。

`devices` and `forward` print stable `<serial-redacted:…>` tags instead of raw ADB serials;
use `adb devices -l` only when an explicit, operator-approved serial is needed
for a physical test. 中文：`devices` 默认只显示稳定的脱敏标签；只有在明确批准的
真机测试中才使用 `adb devices -l` 查看原始 serial。

构建并打开当前 SwiftUI 产品壳：

```text
tools/build-mac-app.sh
open mac/.build/app/DroidMatch.app
```

构建脚本会在输出文件系统的稳定私有事务中生成 `.icns`、复制中英文资源、组装并严格验证候选 `.app`；有效的内置 adb 厂商签名保持不变，只有完全未签名的自定义 adb 才补本地签名，已有但验证失败的签名会直接拒绝，外层 App 的 ad-hoc resource seal 仍绑定其精确字节。候选阶段验证全部静态树、资源、签名与 entitlement，只把 macOS 会在私有事务路径误杀的 `adb version` 延后；原子发布后会在最终路径运行完整 verifier，失败即在完成标记前恢复旧 App（首次发布则撤回），且只对精确的瞬态 `embedded adb is not runnable` 最多额外重试两次。其他错误立即失败。首次发布使用 `RENAME_EXCL`，替换既有 App 使用带前后身份复核的 `RENAME_SWAP`。任何 stale-transaction recovery 之前和最终发布之前会两次检查目标 App 的活跃进程；命中时不改变 canonical/transaction，检查不可用也 fail closed。Darwin 会同时比较 `proc_pidpath` 的当前 vnode 路径与 `KERN_PROCARGS2` 中保留的原启动可执行路径，因此 unlink、rename 或 swap 都不能绕过；Linux 离线门禁同时读取 `/proc` executable link 与 argv0。行为测试覆盖运行中 rename、替换和 unlink，事务测试还证明 `swapping` 中断后若 canonical 已启动，下一次构建不会先行 recovery；M0 源码契约固定两次 guard 的数量与顺序，mac-skeleton 也显式运行平台行为测试。离线 SIGKILL 矩阵覆盖首次安装、发布后验证、验证成功到 durable state 的两侧，以及 `rollback-required`、回滚交换和 `rolled-back`；下一次运行只保留已完整验证的 App，其他状态恢复或撤回，并对活动、旧版、不一致或不安全事务 fail closed。这不代表电源故障耐久性。发布前最后一次检查后的窄启动竞态仍由进程级 AppSupport monitor 兜底：运行中的旧进程无法接管 swap 后的新可执行文件，monitor 会通过 `proc_pidinfo` 读取 dyld image zero 已映射 vnode 的 device/inode 身份，并每两秒复核发布路径，即使所有窗口关闭也继续存活。替换、移除或非普通文件会一次性、不可逆地使 discovery、可信设备 Keychain 列表和 session 三个模型入口失效，取消/作废迟到结果，并按既有会话 teardown 断开设备；进程级窗口租约让共享 discovery 保持到最后一个活跃窗口离开，所有窗口随后移除旧交互而显示退出重开提示，⌘R 菜单也 fail closed。monitor 本身不读取钥匙串或自动启动另一进程；已进入 Security.framework 的请求可能由系统退场，但不能发布或启动后续工作。一项 monitor 文件/轮询/停止/不可逆回归、一项多窗口租约回归和三项模型入口回归覆盖该边界，M0 源码契约还会逐项拒绝接线删改。输出父目录缺失时会创建，但既有目录的 mode（包括共享目录 sticky bit）保持不变；离线测试会在成功构建前后精确复核。它仍只是 ad-hoc 本地组装，不是 Developer ID 签名或公证。

CI 使用 `--configuration release` 分别组装普通与 sandbox App。结构化 verifier
会先要求当前静态 bundle 树只包含 owner 可读/可遍历的真实目录和 owner 可读的单链接
普通文件，拒绝 symlink、硬链接、FIFO/其他特殊节点、不可读子树、特殊权限位和
group/world-write，遍历错误也 fail closed；随后再检查 bundle identity、唯一产品
可执行文件、本地化/icon、根级 DroidMatch 隐私清单、嵌套
SwiftProtobuf 隐私清单和签名；sandbox 版本还要求
精确 entitlement allowlist、单独签名且可运行的内置 adb 与非空 NOTICE，普通版本则
禁止意外携带 entitlement 或 platform-tools。entitlement 通过受支持的
`codesign --entitlements - --xml` stdout 契约提取；离线 fake-codesign 回归会拒绝
已弃用的 `:-` 形式、非 XML 输出及上述不安全文件系统形态。
Mac release bundle 还会在 `Contents/Resources/Legal` 携带实际静态链接的
SwiftProtobuf 1.38.1 notice 与完整 Apache-2.0 文本，并由 verifier 检查版本归属。

重新生成 Swift protobuf 文件需要本地安装 `protoc`。默认生成命令会自动调用
`tools/bootstrap-swift-protobuf.sh`，从 `mac/Package.resolved` 的精确 revision
构建并原子安装插件；bootstrap 会在构建前后验证 checkout 干净且 revision/快照未变：

```text
brew install protobuf
bash tools/generate-swift-proto.sh
```

可先单独运行 bootstrap 作为预热。只有显式设置
`PROTOC_GEN_SWIFT=/absolute/path/to/protoc-gen-swift` 才会绕过默认 bootstrap；
显式空值同样绕过并立即 fail closed，不会改动既有生成树。

ADB forward：

```text
adb shell am start -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity --ei port <android-port>
swift run --package-path mac droidmatch-harness forward --serial <serial> --remote-port <android-port>
```

如果省略 `--local-port`，harness 使用 `adb forward tcp:0 ...`，并打印 adb 分配的 `local_port`。
`DebugHarnessActivity` 只存在于 Android debug APK，用于真机 smoke 时保持 endpoint 进程可运行；release manifest 不暴露这个入口。

Raw framed echo：

```text
swift run --package-path mac droidmatch-harness framed-echo --port <local-port> --payload hello
swift run --package-path mac droidmatch-harness framed-echo --port <local-port> --hex 68656c6c6f
```

Protobuf handshake smoke：

```text
swift run --package-path mac droidmatch-harness handshake-smoke --port <local-port>
```

M1 control-plane smoke：

```text
swift run --package-path mac droidmatch-harness m1-smoke --port <local-port>
```

MediaStore 目录列表 smoke：

```text
swift run --package-path mac droidmatch-harness list-dir --port <local-port> --path dm://media-images/
swift run --package-path mac droidmatch-harness list-dir --port <local-port> --path dm://media-videos/
swift run --package-path mac droidmatch-harness list-dir-expect-error --port <local-port> --path dm://saf-missing/ --expected-error-code notFound
```

SAF 目录列表 smoke：

1. 在 Android 端点击 DroidMatch 前台服务通知，选择一个目录并授权。
2. 运行 `m1-smoke` 或 `list-dir --path dm://roots/`，从 root listing 里取 `dm://saf-.../` 路径。
3. 验证授权目录：

```text
swift run --package-path mac droidmatch-harness list-dir --port <local-port> --path dm://saf-<stable-id>/
```

传输 smoke：

```text
swift run --package-path mac droidmatch-harness download-once --port <local-port> --source-path dm://media-images/media/<id>
swift run --package-path mac droidmatch-harness download-once --port <local-port> --source-path dm://saf-<stable-id>/<opaque-file-id>
swift run --package-path mac droidmatch-harness download-cancel --port <local-port> --source-path dm://media-images/media/<id>
swift run --package-path mac droidmatch-harness download-pause --port <local-port> --source-path dm://media-images/media/<id>
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /private/tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://saf-<stable-id>/<opaque-file-id> --destination /private/tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /private/tmp/droidmatch-download.bin --resume
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /private/tmp/droidmatch-download.bin --retry-on-transport-loss
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --stop-after-bytes 1
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --resume
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --retry-on-transport-loss
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.jpg --destination-path dm://media-images/droidmatch-upload.jpg
swift run --package-path mac droidmatch-harness upload-open-expect-error --port <local-port> --source /tmp/droidmatch-upload.jpg --destination-path dm://media-images/droidmatch-upload.jpg --requested-offset 1 --expected-error-code unsupportedCapability --expected-message-contains "upload resume is not supported"
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://saf-<stable-id>/droidmatch-upload.bin
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://saf-<stable-id>/droidmatch-upload.bin --stop-after-bytes 1
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://saf-<stable-id>/droidmatch-upload.bin --resume
swift run --package-path mac droidmatch-harness dual-download-smoke --port <local-port> --source-path-a dm://app-sandbox/a.bin --source-path-b dm://app-sandbox/b.bin --chunk-size-bytes 1048576
swift run --package-path mac droidmatch-harness mixed-transfer-smoke --port <local-port> --download-source-path dm://app-sandbox/a.bin --download-destination /private/tmp/a.bin --upload-source /tmp/b.bin --upload-destination-path dm://app-sandbox/b.bin --chunk-size-bytes 1048576
```

下载路径中的用户或卷符号链接 component 会被拒绝；macOS 固定的 `/var`、`/tmp`、
`/etc` 系统别名会先映射到 `/private/...`，再逐 component 以 `O_NOFOLLOW` 打开。
设备脚本仍使用 `/private/tmp` 作为可比较的证据路径约定；上传源只读打开，不受下载
目标命名空间 reservation 约束。

Harness failures stay privacy-bounded: typed remote RPC failures expose only
the stable error code (for example `notFound` or `permissionRequired`), while
provider messages, paths, document IDs, and local exception text remain
redacted. This makes a physical smoke failure diagnosable without turning the
CLI into a data-disclosure boundary.

Harness 失败信息保持隐私边界：远端 RPC 失败只显示稳定错误码（例如
`notFound` 或 `permissionRequired`），provider message、路径、document ID
和本地异常原文仍会脱敏。这样真机 smoke 可诊断，同时不会把 CLI 变成数据泄露边界。

普通 `download` 是 async receiver-paced 单流路径：Mac 逐块校验 CRC32、写入并 ACK，Android 在第一个 ACK 后按协议上限保持最多 4 个 chunk 或 2MiB in-flight。`dual-download-smoke` 通过同一个 async multiplexer 先打开两条下载流，再按 request/stream ID 路由并公平处理；它还要求双流均活跃且首块尚未 ACK 时 heartbeat 仍能响应。`mixed-transfer-smoke` 同样走产品 async client，在两条不同方向 stream 均 open 后验证 heartbeat，再并发完成原子下载和窗口上传。

`upload` 仍是单流，但使用对称的 `UploadWindow`：Mac 发送侧维持最多 4 个 chunk /
2MiB 在途，连续填满窗口、收一个 ACK、再补发；这把吞吐从 stop-and-wait 实测
11.49 MiB/s 提升到已归档的 33.51 MiB/s Slot D 真机结果。Android 端只校验 chunk
顺序到达，无需改线协议。

下载数据先写入目标旁的 `.droidmatch-part`。writer 固定已授权目录，fresh 流程先无截断
打开并 `flock` 单链接普通 partial，安全删除 sidecar，再在同一锁定 FD 上 `ftruncate`，
全部重置成功后才连接。完整接收后创建并同步固定 commit marker；目标缺失走
`RENAME_EXCL`，已有目标走验证过的 `RENAME_SWAP`，并把旧目标保留到 sidecar 已删除。
随后才删除旧目标、同步目录并退役 marker；finalize 前失败或取消会恢复旧目标与 partial。
目录同步是提交协议的必需步骤，但不扩张为完整断电耐久性保证；advisory lock 也不抵抗
同 UID 恶意绕锁竞态。

`download-cancel` 会在首块后发 `CancelTransferRequest` 验证活动传输可释放；
`download-pause` 会在首块后发 `PauseTransferRequest` 并验证可恢复 offset；
`download --resume` 从 part 文件续写，并依赖 `.droidmatch-transfer.json` 中的 Android
source fingerprint。app-sandbox 和 SAF `upload --stop-after-bytes` 留下本地
`.droidmatch-upload-transfer.json`，随后 `upload --resume` 从已确认 offset 续传。

`download --retry-on-transport-loss` 会在 transport close/timeout 或远端 `transportLost`/`timeout` 后重新建 session、重新 handshake，并用 sidecar 自动重试；默认行为与历史一致（最多重试一次），加 `--max-retry-attempts N` 可开启完整恢复队列（多次重试 + 指数退避，`--retry-backoff-ms M` 控制基准退避，默认 500ms，退避上限 30s，无抖动以便真机日志复现）；`upload --retry-on-transport-loss` 只允许 app-sandbox/SAF 目标，并从已写入 sidecar 的 transfer id / next offset 边界继续，同样支持 `--max-retry-attempts` / `--retry-backoff-ms`。`tools/run-m1-device-smoke.sh --download-retry-fault-check` / `--upload-retry-fault-check` 会把 harness 临时接到 `tools/m1-fault-proxy.py`，在第一条传输连接的第三个 server frame 后断开连接，并要求最终输出 `recovered=true`；app-sandbox-only 的 `--upload-retry-ack-loss-check` 会读到但不转发首个 upload ACK，验证 Android partial 回退后 Mac 可重发。fresh `upload` 目前支持 `dm://app-sandbox/<file>`、`dm://media-images/<file>`、`dm://media-videos/<file>` 和 writable `dm://saf-.../<file>` / `dm://saf-.../doc/<directory-token>/<file>`；SAF upload resume 使用 Android 端 transfer-id hidden partial 文档；`upload-open-expect-error` 用于验证 MediaStore fresh-only provider 对非 0 offset upload open 返回预期错误，不会发送文件 chunk。恢复队列核心 `RecoveryPolicy` 位于 `mac/Sources/DroidMatchCore/RecoveryPolicy.swift`，同步与异步执行器共用相同尝试/退避语义；产品 `AsyncDownloadCoordinator` 负责 partial/source fingerprint 下载恢复，`AsyncUploadCoordinator` 负责稳定源读取、窗口 refill 和逐 ACK checkpoint，`AsyncTransferScheduler` 负责 FIFO/双并发和可观察作业生命周期。上传本地 TCP 测试会先发送 8 字节但只持久化 offset 2，再断线并从 2 重放到完整 10 字节；任务取消会保留 offset 2 且不发起下一连接。Presentation model、设备隔离 manifest、bookmark 租约和持久化/中断状态 UI 已装配进视觉 App target；Slot C 双/混合流、sandbox 产品队列恢复、权限撤销和物理 USB 拔插均已有归档证据，剩余工作是产品 USB 插入时延、更多 OEM SAF provider 矩阵以及明确暂缓的 Developer ID/公证。

跨 scheduler 重建的队列持久化是显式 opt-in：调用方创建 `TransferQueuePersistenceStore(fileURL:)`，再通过 `AsyncTransferScheduler.restoring(...)` 重建。manifest 使用版本化 JSON 和原子写，保留稳定 UUID/FIFO；任务从 queued 进入 active 前必须先写盘成功。重建时只有结构/路径有效、total 已知无冲突且 `0 <= offset < total` 的 download 或 app-sandbox/SAF upload checkpoint 会变成 paused/resumable；`offset == total`、`0 / 0`、unknown/conflicting total、MediaStore active、缺失或损坏 sidecar 都保留为不可 resume 的 `interrupted`。v2 upload 在尚未持有 bookmark lease 的 restore 阶段只校验结构/路径，lease 建立后 coordinator 会在 client factory 前精确 snapshot 并拒绝 stale source。Manifest、sidecar 与 App-owned bookmark registry 共用 private atomic writer：保存使用固定 `.<name>.pending`，目标缺失走 `RENAME_EXCL`、已有目标走 `RENAME_SWAP`；删除使用固定 `.<name>.removing`。完整 stat、parent 重绑定、文件与目录 fsync 都必须成功；失败要么证明回滚，要么返回 `commitUncertain` 并保留 recovery node。每个固定 parent 的 `.droidmatch-private-atomic-lock` 会把同进程与跨进程 read/save/remove 串行到同一永久 inode；节点必须是当前 euid 所有、精确 `0600`、零字节、单链接普通文件，并在 no-follow 打开与独占 `flock` 后复核命名项/FD 身份。不安全锁节点在数据访问前 fail closed；崩溃 marker 仍保留现场。恶意同 UID 进程仍可绕过 advisory lock 并竞态最终 full-stat→unlink 窄窗口。已有宽权限父目录也不会产生 chmod 前暴露窗口。失败 bookmark mutation 会回滚内存记录。产品只在认证证明完成后派生不透明 owner，其存储 key 仅 AppSupport SPI 可读且常规输出强制脱敏；bookmark archive v2 按 `(owner, endpoint)` 隔离记录，因此另一设备的空队列不会误删离线设备授权，同路径的另一 owner 记录也不能满足恢复覆盖。一个进程级 factory 共享唯一 store actor 和 FIFO gate，并把完整的 held restore、注册入队、删除、重试与 owner-only prune 串行化。v1 仅路径记录不会被猜测归属，而是保留为 legacy-unscoped fallback，本阶段不清理。产品恢复始终先持有 execution latch，再对所有非终态本地 endpoint 验证当前 owner 或明确 legacy 的 bookmark 覆盖；损坏/不可读的恢复存储，或对这些目标为空、不完整、仅属于另一 owner 的 archive，均保持 `writeFailed` 且不启动 executor。显式重试会先 load bookmark，再在 execution latch 下 reload/validate/canonicalize manifest，然后按新目标集核对 owner 覆盖并对齐该 owner 的 orphan authority，最后才解锁 scheduler；Resume 也经过同一健康守门，不做乐观恢复。断开会话会在保守暂停写盘后不可逆失效旧 scheduler；旧界面的延迟动作不能恢复、删除或覆盖新会话 manifest。harness 保持显式 opt-in；产品 App 已按认证设备隔离 Application Support manifest，通过 App-owned bookmark 恢复 sandbox 文件访问。

真机一键脚本适合记录可复现 smoke，尤其是需要安装 debug APK、启动 `DebugHarnessActivity` 和清理测试上传目标时。脚本会用 Swift release 配置构建并调用 Mac harness；debug/Onone 吞吐仅供诊断，不能作为 gate 证据：

```text
tools/run-m1-device-smoke.sh --upload-source /tmp/droidmatch-upload.jpg --upload-destination-path dm://media-images/droidmatch-upload.jpg --upload-resume-unsupported-check --min-upload-bytes 1 --cleanup-upload-destination
```

`--upload-resume-unsupported-check` 会先请求 offset 1 的 upload open，并要求 Android 返回 `unsupportedCapability`，只适合 MediaStore 这类 fresh-only provider 的边界记录。SAF 目标应使用 `--upload-resume-check` 验证 partial/resume。需要记录 sidecar-backed transport retry 时，下载加 `--download-retry-on-transport-loss`，app-sandbox/SAF 上传加 `--upload-retry-on-transport-loss`；默认保持历史单次重试，额外传 `--max-retry-attempts N` / `--retry-backoff-ms M` 可在真机日志中记录多尝试恢复队列策略。需要真实注入 Mac 侧连接断开时，分别使用 `--download-retry-fault-check` 和 `--upload-retry-fault-check`；需要覆盖 Android 已写入但 ACK 没到 Mac 的 app-sandbox 窗口时，使用 `--upload-retry-ack-loss-check`。100MiB download 矩阵运行应加 `--chunk-size-bytes 1048576 --min-download-mib-per-second 20`，匹配的 upload 运行应加 `--min-upload-mib-per-second 20`；harness 输出会包含 `elapsed_ms` 和 `throughput_mib_per_sec`，脚本会写入日志并在低于阈值时失败。历史 Slot A debug/Onone 结果还早于当前传输优化，只能作为诊断，必须在当前代码上以 release harness 重跑两方向。MediaStore upload 不支持这个上传重试路径。协议已有 SAF delete mutation；`--cleanup-upload-destination` 对 app-sandbox 用 `run-as` 删除私有文件；对 MediaStore 只清理 `dm://media-images/<name>` / `dm://media-videos/<name>` 这种 root 下单段文件名，并在 Android 10+ 限定到 DroidMatch 写入的 `Pictures/DroidMatch/` 或 `Movies/DroidMatch/`；对直接 root 的单文件 SAF 目标会通过新的 fresh protocol `delete-path` session 自动删除，嵌套 `dm://saf-.../doc/<directory-token>/...` 仍需手动清理，因为 token 只在当前 session 有效。

`download` / `upload` 成功行还分别输出 caller 请求的
`requested_chunk_size_bytes` 与 Android 接受的 `chunk_size_bytes`。Slot A 正式归档由
`tools/run-m1-throughput-gate.sh` 同时要求两方向的这两个值都为 1048576，并在双向精确
100 MiB、阈值、current-main provenance 和清理验证全部通过后才发布证据。
