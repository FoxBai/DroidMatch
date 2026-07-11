# DroidMatch Mac 端

这里是 DroidMatch Mac 端实现目录。

M1 起点：

- 先构建命令行或最小验证壳，不构建完整产品 UI。
- 验证 ADB 发现、授权、forward、握手和重连。
- 实现 `RpcEnvelope` 的 length-prefixed Protobuf 编解码。
- 跑通 `DeviceInfoRequest`、`ListDirRequest`、`OpenTransfer`、pause、cancel 和 resume。
- 收集 M1 需要的诊断日志和性能指标。

M0 规格已经收口，见 `docs/m0-closeout.md`、`docs/architecture.md` 和 `docs/protocol.md`。

`DroidMatchCore` 承载协议与资源 actor，原生界面状态边界位于独立 `DroidMatchPresentation` library，Keychain/bookmark 等平台适配位于 `DroidMatchAppSupport`。`DroidMatchApp` 已接通安全的 ADB 设备发现、动态 forward lease、SAS 首配/Keychain 重连认证、可信 Android 列表/撤销，以及认证后分页文件浏览、结构化诊断和按认证设备隔离的持久双向传输队列。撤销信任前会等待活动会话完全断开；界面只接收进程内匿名 ID、名称和时间，不接收 pairing ID 或指纹。`--sandboxed` 构建会内置并单独签名 adb、携带 NOTICE 和最小 entitlement；该 bundle 已在本机只读发现两台设备，sandbox 文件传输仍待验证。

诊断页可通过原生保存面板导出 schema v1 JSON 支持报告。编码器使用显式 allowlist，只包含已脱敏的设备概况、权限枚举、服务状态、错误数量与已知计数器；不存在 ADB serial、pairing ID、指纹、端口、文件名/路径、凭据、原始异常或原始日志字段。

文件浏览器的搜索与名称/修改时间/大小排序都重新提交完整 provider 查询，Android 在分页前完成过滤和排序；Mac 不会只重排当前页而制造跨页顺序错误。改变排序会清除选择态并使旧请求 generation 失效。
列表和媒体网格都直接格式化 provider 返回的毫秒时间戳，并提供符合条目能力的原生右键菜单；下载、重命名和确认删除仍回送既有产品动作，不在 view 内复制权限判断或远端操作。

## 当前已实现

- `DirectoryMutationClient` / `DirectoryBrowserModel`：通过 async RPC 在 App Sandbox 或可写 SAF 当前目录创建直接子文件夹；切换目录会取消旧 mutation，错误状态只保留分类而不保留用户输入名称。
- 同一 mutation 边界支持对可写普通文件/目录执行原地重命名，成功后原子刷新当前页；虚拟 root、跨目录移动和不安全名称在产品或 provider 边界被拒绝。
- 删除入口只出现在可写普通条目上，并显示文件/递归目录不同的破坏性确认文案；确认前不发 RPC，成功后刷新当前目录，错误状态不保留条目名称。
- SwiftUI 搜索框经过 250ms debounce 后发起新的目录查询；进入子目录会清空搜索，返回历史目录会恢复搜索条件，generation guard 拒绝旧结果。
- 选择模式仅接受当前可见、可写的普通条目；批量删除按 logical path 稳定排序逐项执行，目录保留 recursive 语义，中途失败会刷新目录并显示部分失败而不伪造事务回滚。
- 文件浏览区支持 Finder 多文件拖放上传：只接受最多 100 个名称唯一的 regular file URL，命中时显示明确 drop target；每项仍通过 `BookmarkingTransferQueueDataSource` 保存 security-scoped bookmark 并形成独立持久任务。
- MediaStore 图片/视频目录默认使用自适应原生网格并可切换回信息密度更高的列表；两种布局都只为可见项按需请求 96 px 缩略图，点击后在原生 sheet 请求最长边 512 px 的预览。Core 拒绝非媒体路径、越界尺寸、超过 512 KiB 的响应和异常 MIME/尺寸，Presentation 最多缓存 64 项并在切换目录时取消在途请求。预览仍是系统生成的有界 derivative，不经控制 RPC 读取完整原文件。
- 图片相册根与相册内部都使用媒体网格；根目录只为可见相册懒加载 Android 选取的最新图片封面，点击目录则进入相册而不是打开图片预览。相册条目由 Android 返回，Mac 不合成或解析 bucket token。相册内媒体仍使用平面图片视图的唯一 logical path，因此选择、缩略图缓存、预览和下载不会产生双重身份。
- 多选下载与批量删除分别按 `canRead`/`canWrite` 启用；下载前选择本地目录，规范化名称重复或目标文件已存在会整批拒绝，每项仍注册父目录 bookmark 并形成独立可恢复任务。

- `AdbClient`：选择 adb 路径、解析 `adb devices -l`、创建/list/remove adb forward。
- `AdbDeviceDiscovery` / `DeviceDiscoveryModel`：在私有队列执行有 5 秒上限的阻塞 ADB listing，Core 内把 serial 映射为进程内 UUID，再以可取消、可防旧响应覆盖、失败时标记 stale 的 MainActor 状态交给产品 UI。同一 actor 按匿名 UUID 创建动态 `tcp:0 → tcp:39001` lease，私下保存 serial/端口清理所有权，并在取消、异常端口、失败或断开时幂等移除 forward。
- `ProductDeviceSessionCoordinator` / `DeviceSessionModel`：Core actor 用 Hello-only 新连接读取身份选择器，按精确指纹选择 Keychain 记录，再以第二条新连接完成双向 proof；没有记录时通过 Android 可见窗口和 Mac 六位 SAS sheet 首配。generation 拒绝旧操作，连接/配对/取消/失败统一关闭 socket 并释放 lease；MainActor 只发布稳定失败类别、设备名和 SAS，不持有 serial、端口、密钥或原始异常。
- `ProductDeviceDiagnostics` / `DeviceDiagnosticsModel`：在认证会话上并发读取 device-info 与 diagnostics，丢弃 Android device ID、事件/错误原文、线程名、任意 counter key 和畸形值；只把 allowlist 权限/计数器、粗粒度服务状态、错误数量、存储、电池和系统版本交给 MainActor。刷新失败保留明确标记为 stale 的上次健康快照。
- `FrameCodec` / `FrameReader`：4 MiB 上限的 length-prefixed frame 编解码。
- `TransportError`：异步 transport 与恢复策略共享的稳定错误分类；旧同步 TCP client/session 已删除。
- `AsyncFramedTcpSession`：面向产品层的 actor 化非阻塞 transport 边界；连接会在首次使用时永久选择 FIFO round-trip 或 multiplexed I/O，禁止混用。multiplexed 模式保持 send FIFO，但允许 RPC 层唯一 reader 独立等待；空闲 reader 不套用 request timeout，连接关闭会唤醒全部排队 I/O。
- `RpcEnvelopeCodec`：同步 harness 与 async 产品客户端共享的 envelope 构造/校验逻辑；统一检查 `frame_version`、可选 payload CRC、request ID、frame kind 和 payload type。
- `AsyncRpcControlClient` / `AsyncRpcMultiplexer`：要求先完成 Hello；注入 `PairingCredentials` 时继续完成双向 proof 并拒绝降级。唯一 reader 按 request ID 路由并发控制响应，按 request/stream ID 路由最多两条活跃传输；`AsyncRpcRoutingState` 只保存 route record、request ID 轮转和纯验证，不拥有 actor/task/socket。公开 `AsyncDownloadTransfer` / `AsyncUploadTransfer` handle，下载使用 4 chunk / 2MiB 有界队列，上传 handle 当前逐 chunk 等 ACK。control/open/ACK deadline 或其等待任务取消、transport failure、协议错位会关闭 session；单次 download `nextChunk` 等待取消不会偷走 reader，remote application error 也保持 session 可用。
- `TransferResumeRecords` / `AsyncTransferResumeStore`：把 CLI 与产品共用的 download/upload sidecar schema 收口到 Core；保留历史 camelCase JSON 兼容，所有阻塞文件操作在私有串行队列执行。
- `TransferWireMetadata`：Android 只按逻辑 `destination_path` 授权上传，因此产品和 harness 的 inactive-side `source_path` 统一使用 `mac-local-upload`；真实 POSIX 路径只留在 Mac sidecar 做恢复身份校验。普通成功输出也只显示 `<local-file>` / `<local-partial>` / `<local-sidecar>`。
- `DroidMatchHarness/main.swift` / `HarnessTransferCommands.swift`：前者负责 CLI 分派、ADB/control probes、帮助与共享解析，后者集中 download/upload/error-boundary 命令；两者都只消费 Core，不另建产品架构。
- `AsyncDownloadCoordinator`：通过注入的 client factory 在每次尝试创建并认证新连接，持久化 Android 接受的源指纹，按实际 partial 长度用同一 transfer ID 重开，并以可取消指数退避自动恢复；成功后清理 sidecar，损坏或孤立 checkpoint 则显式失败。
- `AsyncUploadFileSource` / `AsyncUploadCoordinator`：私有串行队列读取并在每次 I/O 前后校验 size、纳秒 mtime、filesystem/inode；持续填充 4 chunk / 2MiB 窗口，按每个有序 ACK 原子推进 sidecar，app-sandbox/SAF 断线后用同一 transfer ID 和最后 ACK offset 重开。MediaStore 保持 fresh-only。
- `AsyncUploadFileSender` / `AsyncMixedTransferSmokeClient`：把稳定文件读取到 4 chunk / 2MiB 窗口的 pump 从 coordinator 中提取复用；mixed smoke 在独占 async session 上先 open 下载/上传，在下载尚未 ACK、上传尚未发 chunk 时要求 heartbeat 往返，再并发完成原子接收和窗口上传，最后复验本地上传源。inactive-side upload source 固定为 `mac-local-upload`，不会把本机路径或真实文件名发送到远端诊断。
- `DirectoryListing` / `DirectoryBrowserModel`：Core 把 protobuf listing 转成 typed query/page/entry/error，原样回传 opaque token，并校验内嵌错误、row identity、kind 和 token 防环；MainActor 模型串行执行 load/refresh/load-more，切换 path 时拒绝旧响应，刷新失败保留 stale rows，翻页失败保留 token 可重试，跨页 path 重复只展示一次。设备文件名只进入展示 row，不进入失败状态或日志。
- `AsyncTransferProgress` / `AsyncTransferRateEstimator` / `AsyncTransferScheduler` / `TransferQueuePersistenceStore`：默认是进程内 FIFO 产品队列，最多同时运行两项；可显式通过版本化原子 manifest 跨 scheduler 重建。快照除 queued/running/retrying/pausing/paused/completed/failed/cancelled/interrupted、attempt/backoff 外，还提供 `canPause` / `canResume` / `canCancel` / `canRemove`、跨重试单调的 `confirmedBytes` / `totalBytes` / 完成比例，以及基于单调 uptime、两秒时间加权窗口的 `recentBytesPerSecond`。取消中的 executor 真正退场前 `canRemove` 保持 false。下载只在 partial 写入并 ACK 后推进，上传只在 ACK（可恢复目标还要求 sidecar 保存）后推进；最终完成值还要求各自的本地校验和 checkpoint 清理。排队任务可直接挂起；运行中的下载或 app-sandbox/SAF 上传只在持久断点建立且未到 100% 时可暂停，关闭该任务的独占 coordinator session 后保留 checkpoint，并以同一 job/transfer ID、`resume: true` 放回 FIFO 队尾。MediaStore 运行中暂停被明确拒绝；持久模式也会在 executor 启动前先写盘，并把无可信 sidecar 的 active 工作变为禁止自动重放的 `interrupted`。重试与暂停会清空速率窗口，运行态两秒无新确认会自动发布 nil，进入终态则冻结当时仍有效的样本。调度器只组合 coordinator，不解析协议。
- `DroidMatchPresentation` / `TransferQueueModel`：独立于 Core 的 macOS 13+ Combine 边界，在 MainActor 上把 buffering-newest scheduler 快照映射成稳定有序的展示项，并发布脱敏的持久化健康状态。订阅显式、幂等且可重启；stop 保留最后快照，旧 generation 不能覆盖新订阅；动作不做乐观改写，等待 scheduler 权威更新。下载提交只接受 `dm://` 源和本地 file URL；展示项只包含本地 basename 与经过 scheme 校验的可选远端逻辑路径，也不携带可能含 POSIX 路径的原始 failure description。
- `DroidMatchApp`：SwiftUI `NavigationSplitView` 产品壳，中英文设备总览可直接展示真实 ADB 发现结果，但不显示 serial；文件页以原生 `NSSavePanel` 选择下载目标、以 `NSOpenPanel` 选择单个上传源，并只在认证能力和当前目录都允许写入时开放上传。传输页展示双向真实进度、速率和暂停/继续/取消/移除动作。当前队列随设备会话结束，不伪装持久 bookmark 支持。
- `HandshakeSmokeClient`：为每次连接生成 32 字节随机 nonce，可携带 pairing ID，并校验 `ServerHello` 的 request ID、协议、transport、nonce 回显、server nonce 与认证状态。
- `SessionAuthenticator`：配对会话认证的纯密码学内核，按固定 big-endian transcript 生成 SHA-256、role-separated HMAC proof 和 HKDF session key；Swift/Java 共用同一 fixture，现已接入 async paired reconnect 状态机。
- `PairingAuthenticator`：首次配对的 CryptoKit P-256 ECDH、canonical transcript、两路 HKDF、无偏六位 SAS 和三阶段 confirmation；与 Java 共用固定测试向量。
- `AsyncPairingClient`：一次性执行 start/confirm/finalize，先验证 Android 稳定设备身份签名，再把 SAS 和设备指纹交给异步审批闭包；仅在双向 confirmation 成功后临时写 Keychain，finalize 失败会撤销。产品层需提供真实 Mac 审批 UI，并使用长于 Android 审批等待的 transport timeout。
- `KeychainPairingCredentialStore`：使用禁止同步的 generic-password item 保存完整 pairing record，支持更新、列表和撤销，并拒绝同一 pairing ID 静默绑定另一设备指纹；已接入 async pairing client，真实 app access-group 仍需集成测试。
- `M1SmokeClient`：通过 `AsyncFramedTcpSession` / `AsyncRpcControlClient` 在同一连接上连续跑 handshake、heartbeat、device info、`dm://roots/` root listing 和 diagnostics；`m1-smoke` 的命令名、能力协商与成功输出保持兼容。
- `TransferResults` / `RpcControlClientError`：async 下载/上传结果与协议校验错误；旧同步 `RpcControlClient` 已删除。
- `droidmatch-harness`：提供 adb/path/devices/frame/forward/framed-echo/handshake-smoke/m1-smoke/dual-download-smoke/mixed-transfer-smoke/list-dir/list-dir-expect-error/download-once/download-cancel/download-pause/download/upload 命令。

Swift protobuf codegen 已接入，`m1-smoke` 是当前 Android endpoint 的正式 M1 control-plane 联通命令，会在同一连接内验证 handshake、heartbeat、device info、root listing 和 diagnostics。`handshake-smoke` 可在 async FIFO session 上单独排查 hello 阶段，并把 `pairingRequired` 作为合法诊断结果返回而不进入认证；`framed-echo` 同样走 async FIFO session，保留给本地 echo server 或旧 placeholder endpoint 做 frame 层排查。

全部产品和 CLI 网络路径都已迁到真正非阻塞的 async session，包括完整/部分上传、逐 ACK sidecar、resume、ACK-loss 重放与 transport retry；旧同步 client 已无调用。async pause 不会 ACK 已收到的首块，返回 offset 始终停在最后确认边界。SwiftUI 产品代码不在 MainActor 调用同步 session，也不使用 `Task.detached` 包一层伪异步；产品会话、真实目录页和结构化诊断页均通过 Core/Presentation 边界。普通与 sandbox release bundle 的结构、签名和精确 entitlement 已自动验证；尚未完成的是 sandbox 产品认证/文件传输与混合流真机证据。

## 命令

本地验证：

```text
bash tools/run-swift-tests.sh
swift run --package-path mac droidmatch-harness frame-self-test
swift run --package-path mac droidmatch-harness devices
```

构建并打开当前 SwiftUI 产品壳：

```text
tools/build-mac-app.sh
open mac/.build/app/DroidMatch.app
```

构建脚本会生成各尺寸 `.icns`、复制中英文资源、组装标准 `.app` 并执行 ad-hoc 签名与严格校验。它不是发布签名；Developer ID、公证和 DMG 仍需完整 Xcode 与发布凭据。

CI 使用 `--configuration release` 分别组装普通与 sandbox App。结构化 verifier
检查 bundle identity、唯一产品可执行文件、本地化/icon、根级 DroidMatch 隐私清单、嵌套 SwiftProtobuf 隐私清单和签名；sandbox 版本还要求
精确 entitlement allowlist、单独签名且可运行的内置 adb 与非空 NOTICE，普通版本则
禁止意外携带 entitlement 或 platform-tools。
Mac release bundle 还会在 `Contents/Resources/Legal` 携带实际静态链接的
SwiftProtobuf 1.38.1 notice 与完整 Apache-2.0 文本，并由 verifier 检查版本归属。

重新生成 Swift protobuf 文件需要本地安装 `protoc`：

```text
brew install protobuf
bash tools/generate-swift-proto.sh
```

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
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://saf-<stable-id>/<opaque-file-id> --destination /tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin --resume
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin --retry-on-transport-loss
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
swift run --package-path mac droidmatch-harness mixed-transfer-smoke --port <local-port> --download-source-path dm://app-sandbox/a.bin --download-destination /tmp/a.bin --upload-source /tmp/b.bin --upload-destination-path dm://app-sandbox/b.bin --chunk-size-bytes 1048576
```

普通 `download` 是 async receiver-paced 单流路径：Mac 逐块校验 CRC32、写入并 ACK，Android 在第一个 ACK 后按协议上限保持最多 4 个 chunk 或 2MiB in-flight。`dual-download-smoke` 通过同一个 async multiplexer 先打开两条下载流，再按 request/stream ID 路由并公平处理；它还要求双流均活跃且首块尚未 ACK 时 heartbeat 仍能响应。`mixed-transfer-smoke` 同样走产品 async client，在两条不同方向 stream 均 open 后验证 heartbeat，再并发完成原子下载和窗口上传。

`upload` 仍是单流，但现已使用对称的 `UploadWindow`（`mac/Sources/DroidMatchCore/UploadWindow.swift`）：Mac 发送侧维持最多 4 个 chunk / 2MiB 在途，单线程内连续发送填满窗口、阻塞收一个 ACK、再补发，把吞吐从 `chunkSize / RTT`（stop-and-wait 实测 11.49 MiB/s）提升到已归档的 33.51 MiB/s Slot D 真机结果；Android 端 `handleTransferChunk` 只校验 chunk 顺序到达，无需改动即可接受窗口化上传。下载中的数据写入目标文件旁边的 `.droidmatch-part`，完整成功后才原子提交到目标路径；`download-cancel` 会在首块后发 `CancelTransferRequest` 验证活动传输可释放；`download-pause` 会在首块后发 `PauseTransferRequest` 并验证可恢复 offset；`download --resume` 会从这个 part 文件续写，并依赖 `.droidmatch-transfer.json` sidecar 里的 Android source fingerprint；app-sandbox 和 SAF `upload --stop-after-bytes` 会留下本地 `.droidmatch-upload-transfer.json` sidecar，随后 `upload --resume` 会请求该 offset 并续传。

`download --retry-on-transport-loss` 会在 transport close/timeout 或远端 `transportLost`/`timeout` 后重新建 session、重新 handshake，并用 sidecar 自动重试；默认行为与历史一致（最多重试一次），加 `--max-retry-attempts N` 可开启完整恢复队列（多次重试 + 指数退避，`--retry-backoff-ms M` 控制基准退避，默认 500ms，退避上限 30s，无抖动以便真机日志复现）；`upload --retry-on-transport-loss` 只允许 app-sandbox/SAF 目标，并从已写入 sidecar 的 transfer id / next offset 边界继续，同样支持 `--max-retry-attempts` / `--retry-backoff-ms`。`tools/run-m1-device-smoke.sh --download-retry-fault-check` / `--upload-retry-fault-check` 会把 harness 临时接到 `tools/m1-fault-proxy.py`，在第一条传输连接的第三个 server frame 后断开连接，并要求最终输出 `recovered=true`；app-sandbox-only 的 `--upload-retry-ack-loss-check` 会读到但不转发首个 upload ACK，验证 Android partial 回退后 Mac 可重发。fresh `upload` 目前支持 `dm://app-sandbox/<file>`、`dm://media-images/<file>`、`dm://media-videos/<file>` 和 writable `dm://saf-.../<file>` / `dm://saf-.../doc/<directory-token>/<file>`；SAF upload resume 使用 Android 端 transfer-id hidden partial 文档；`upload-open-expect-error` 用于验证 MediaStore fresh-only provider 对非 0 offset upload open 返回预期错误，不会发送文件 chunk。恢复队列核心 `RecoveryPolicy` 位于 `mac/Sources/DroidMatchCore/RecoveryPolicy.swift`，同步与异步执行器共用相同尝试/退避语义；产品 `AsyncDownloadCoordinator` 负责 partial/source fingerprint 下载恢复，`AsyncUploadCoordinator` 负责稳定源读取、窗口 refill 和逐 ACK checkpoint，`AsyncTransferScheduler` 负责 FIFO/双并发和可观察作业生命周期。上传本地 TCP 测试会先发送 8 字节但只持久化 offset 2，再断线并从 2 重放到完整 10 字节；任务取消会保留 offset 2 且不发起下一连接。Presentation model、设备隔离 manifest、bookmark 租约和持久化/中断状态 UI 已装配进视觉 App target；下一步是双/混合流与 sandbox 产品队列真机归档、权限撤销/USB 拔插异常场景和真机 SAF 上传矩阵。

跨 scheduler 重建的队列持久化是显式 opt-in：调用方创建 `TransferQueuePersistenceStore(fileURL:)`，再通过 `AsyncTransferScheduler.restoring(...)` 重建。manifest 使用版本化 JSON 和原子写，保留稳定 UUID/FIFO；任务从 queued 进入 active 前必须先写盘成功。重建时只有 sidecar 可解码且路径匹配的 download 或 app-sandbox/SAF upload 会变成 paused/resumable；MediaStore active、缺失或损坏的 sidecar 都会保留为不可 resume 的 `interrupted`，避免静默重复上传。损坏/未知版本的 manifest 不会被自动删除，公开状态只暴露 `disabled`、`healthy`、`writeFailed`，不包含本机路径。harness 保持显式 opt-in；产品 App 已按认证设备隔离 Application Support manifest，通过 App-owned bookmark 恢复 sandbox 文件访问，并在断开会话前暂停或中断队列。

真机一键脚本适合记录可复现 smoke，尤其是需要安装 debug APK、启动 `DebugHarnessActivity` 和清理测试上传目标时：

```text
tools/run-m1-device-smoke.sh --upload-source /tmp/droidmatch-upload.jpg --upload-destination-path dm://media-images/droidmatch-upload.jpg --upload-resume-unsupported-check --min-upload-bytes 1 --cleanup-upload-destination
```

`--upload-resume-unsupported-check` 会先请求 offset 1 的 upload open，并要求 Android 返回 `unsupportedCapability`，只适合 MediaStore 这类 fresh-only provider 的边界记录。SAF 目标应使用 `--upload-resume-check` 验证 partial/resume。需要记录 sidecar-backed transport retry 时，下载加 `--download-retry-on-transport-loss`，app-sandbox/SAF 上传加 `--upload-retry-on-transport-loss`；默认保持历史单次重试，额外传 `--max-retry-attempts N` / `--retry-backoff-ms M` 可在真机日志中记录多尝试恢复队列策略。需要真实注入 Mac 侧连接断开时，分别使用 `--download-retry-fault-check` 和 `--upload-retry-fault-check`；需要覆盖 Android 已写入但 ACK 没到 Mac 的 app-sandbox 窗口时，使用 `--upload-retry-ack-loss-check`。100MiB download 矩阵运行应加 `--chunk-size-bytes 1048576 --min-download-mib-per-second 20`，harness 输出会包含 `elapsed_ms` 和 `throughput_mib_per_sec`，脚本会写入日志并在低于阈值时失败；upload 可用 `--min-upload-mib-per-second <mibps>` 做同类记录。MediaStore upload 不支持这个上传重试路径。`--cleanup-upload-destination` 对 app-sandbox 用 `run-as` 删除私有文件；对 MediaStore 只清理 `dm://media-images/<name>` / `dm://media-videos/<name>` 这种 root 下单段文件名，并在 Android 10+ 限定到 DroidMatch 写入的 `Pictures/DroidMatch/` 或 `Movies/DroidMatch/`。SAF upload smoke 不自动清理，因为当前协议还没有 delete/mutation 路径。
