# DroidMatch Android 端

这里是 DroidMatch Android 端实现目录。

M1 起点：

- 先构建前台服务骨架，不构建完整应用体验。
- 实现 ADB endpoint、RPC dispatcher 和 length-prefixed `RpcEnvelope` 编解码。
- 暴露设备信息、权限状态、目录列表和基础文件传输 provider。
- 按 `docs/android-permissions.md` 使用 SAF / MediaStore-first 权限模型。
- 记录服务状态、权限状态、传输状态和最近错误，供 Mac 端诊断导出。

AOA 入口在 ADB M1 harness 可用后再接入同一套协议面。M0 规格已经收口，见 `docs/m0-closeout.md`。

M1 暂时把 service、transport、protocol、providers、permissions 和 diagnostics 骨架放在 `app.droidmatch.m1` 包内；M1 通过后再按 `docs/architecture.md` 拆模块。

## 当前已实现

- `ForegroundConnectionService`：创建本地化的前台服务通知，产品入口默认启动 `PAIRED_REQUIRED` ADB endpoint，debug harness 显式保留 `NONCE_ONLY` 证据模式；认证模式或端口变化时会关闭旧连接并重建 endpoint，进程被杀后不创建缺少启动参数的空闲 sticky service，并在 Android 15 `dataSync` 超时时立即释放 endpoint 后停止自身。
- `AdbEndpoint`：监听 debug harness 指定端口，只接受 loopback 客户端，设置 handshake/idle timeout，并把连接交给 dispatcher。
- `FramedIo`：读写 `uint32_be length + payload` frame，最大 4 MiB。
- `RpcDispatcher`：负责 envelope 校验、每连接 session phase 顺序和 READY 后 capability 二次守门；错序请求会关闭会话，并在 teardown 同时清理认证与传输状态。
- `RpcAuthenticationHandler` / `RpcSessionState`：处理 `AWAITING_HELLO → AWAITING_AUTH → READY` 重连和 `PAIRING_AWAITING_CONFIRM → PAIRING_AWAITING_FINALIZE` 首配；nonce-only 模式显式标记 `CORRELATED`，paired 模式发新鲜 nonce、验证 proof、维持通用失败外形，并在 READY/CLOSED 前清零临时密钥。
- `RpcTransferHandler` / `RpcTransferStreams` / `RpcTransferRegistry`：在 dispatcher 完成 envelope 与 session phase 校验后，分别负责 open/chunk/ACK/cancel/pause 协议动作、4 chunk / 2 MiB 窗口与 ACK 安全恢复边界、会话级 download/upload handle 身份和 teardown；连接关闭会从 registry 原子移除并释放该会话全部 provider handle。
- `SessionAuthenticator`：与 Mac 端字节级一致的 canonical transcript、SHA-256、角色隔离 HMAC proof、HKDF session key 和常量时间 proof 校验；已接入 pairing reconnect protobuf 与 authentication handler。
- `PairingCredentialRepository` / `SessionAuthenticationMode`：paired 状态机的安全存储边界和显式策略。产品 service 默认选择 `PAIRED_REQUIRED`，debug harness 必须显式请求 `NONCE_ONLY`；Keystore 真机证据仍待归档。
- `PairingAuthenticator` / `PairingKeyAgreement`：使用平台 P-256 ECDH、固定 canonical transcript、两路 HKDF、无偏六位 SAS 和 client/server/final 三类 HMAC confirmation；Swift/Java 共用 `pairing-v1.properties` 固定向量。
- `AndroidDeviceIdentity`：在 Android Keystore 中维护稳定、不可导出的 P-256 签名私钥；首配 response 返回公钥并对包含该公钥的 canonical transcript 签名，Mac 校验后把公钥 SHA-256 作为设备指纹。
- `AndroidPairingCredentialStore`：32 字节 pairing key 由不可导出的 Android Keystore AES-GCM key 包装；pairing ID、设备身份指纹、名称和时间戳全部作为 AAD 认证，密文存入禁备份的私有 SharedPreferences。authentication handler 只在 final confirmation 验证后写入。
- `AndroidDeviceInfoProvider`：返回设备型号、Android 版本、SDK、数据分区容量、电量和 M1 权限状态。
- `PairingApprovalController` / `PairedDeviceManager` / `DroidMatchActivity`：进程级 controller 默认关闭；产品 Activity 可显式启停安全 USB endpoint、展示粗粒度生命周期状态，并仅在 paired endpoint 已监听时允许用户打开 120 秒配对窗口。UI 只显示客户端名和六位 SAS，可批准/拒绝 pending attempt、查看按最近使用排序的已配对 Mac、撤销单项信任并立即关闭现有 USB 会话，同时管理 SAF 目录授权。
- `AuthenticationRateLimiter`：首次配对和重连使用进程级指数退避；重连同时按 pairing ID 与全局失败压力守门，防止随机 ID 轮换绕过。状态五分钟空闲后过期、最多跟踪 256 个 ID，锁定期仍走相同 challenge/unauthorized 外形。
- `DmFileProvider`：负责 M1 root、SAF process-local token cache 与 catalog 路由；`ProviderPathRouter` 负责 logical path/target，`ProviderPagePolicy` 独立负责 query-bound opaque page token、分页上限和默认排序；`AndroidAppSandboxCatalog` 负责 canonical app-private 文件系统，`AndroidMediaCatalog` 负责动态媒体权限与 MediaStore，`AndroidSafCatalog` 负责 persisted tree permission、document query/page/download 和 transfer-ID partial resume；`ProviderDownloadReaders` / `ProviderUploadWriters` 分别拥有传输读取与提交/清理状态，共享 helper 统一 ID、MIME 和 error-path cleanup。
- `CreateDirectoryRequest`：认证会话持有 `file_write` 后可在 App Sandbox 或可写 SAF 目录创建直接子目录；App Sandbox 不隐式创建缺失父目录，SAF 只接收进程内 opaque parent token，MediaStore 明确返回不支持。
- `RenamePathRequest`：App Sandbox 只允许 canonical 同父目录重命名并保持文件/目录 kind；SAF 通过 opaque document token 调用平台 rename，跨 root、MediaStore 与只读 provider 明确拒绝。
- `DeletePathRequest`：禁止删除 App Sandbox/SAF root；非空 App Sandbox 目录和全部 SAF 目录必须显式携带 `recursive=true`，文件与目录 kind 不匹配时拒绝。
- `ListDirRequest.search_query`：App Sandbox/SAF 在排序分页前执行 Locale.ROOT 不区分大小写过滤，MediaStore 使用已转义 `%`/`_`/`\\` 的 selection；搜索词绑定进 page token 且最大 256 字符。
- `ThumbnailRequest`：仅接受 MediaStore 图片/视频 opaque path；API 29+ 使用 `ContentResolver.loadThumbnail`，API 26–28 使用系统缩略图接口，按最长边 32–512 px 缩放并以最多 512 KiB 的 JPEG 响应返回，不读取并传输完整原文件。
- 图片相册：`dm://media-images/albums/` 按 MediaStore bucket 聚合 API 26–34 图片；bucket ID 只在 Android 内参与 selection，Mac 只见严格校验的 96-bit 哈希 token。聚合在过滤/排序后分页，相册内图片复用平面视图的 canonical `dm://media-images/media/<id>` 身份；相册缩略图只查询该 bucket 最新可用图片并复用有界缩略图编码，不读取原图。
  - 为兼容 API 26，首次相册列表会流式扫描轻量 bucket 列并只保留每个相册一条聚合状态；同时填充最多 4096 项的进程内 LRU token→bucket 映射。随后可见封面和进入相册通常 O(1) 解析，服务重启后的旧 token 才回退到一次流式扫描。
- `PermissionStateProvider` / `DiagnosticsReporter`：提供早期权限和诊断状态，诊断计数器有 JVM 并发测试覆盖。
- backup/data-extraction rules：API 26–30 full backup、Android 12+ cloud backup 和 device transfer 均显式排除全部应用私有域，防止未来 pairing key 包装密文、SAF 状态、传输 sidecar 或诊断数据被迁移。
- Gradle app skeleton：可构建 debug APK，包名为 `app.droidmatch`，代码 namespace 为 `app.droidmatch.m1`。
- Android protobuf codegen：Gradle 从根目录 `proto/` 生成 `app.droidmatch.proto.v1` Java lite classes。
- launcher 入口：安装后启动器中显示 DroidMatch 图标，打开 `DroidMatchActivity` 完成安全连接、配对、通知与 SAF 授权管理；它仍不是完整文件管理器。
- launcher visual：单一 adaptive vector 使用深石墨背景、冷玉色/暖白设备端点与暖色匹配桥；Android 13+ 提供 monochrome themed icon，不再维护重复密度 PNG。
- debug harness overlay：debug APK 只额外导出 `DebugHarnessActivity`，便于用 `adb shell am ...` 启动真机 smoke；Activity 再通过应用内显式 intent 启动始终不导出的 service。

当前支持 download 方向的窗口化 open/chunk/ack（每个 stream 最多 4 个 chunk 或 2MiB in-flight），并在同一会话内把上传/下载活跃流总数限制为 2；第三条合法 open 会收到 typed concurrency error，方向和 capability 校验先于并发上限。Mac 的 `dual-download-smoke` 已用本地 TCP 端到端测试证明两条下载流可按 stream ID 交错路由，且双流活跃、首块未 ACK 时 heartbeat 不会被数据面饿死；真机脚本提供显式 `--dual-download-check`，但尚无归档设备结果。

同一会话的活跃 `transfer_id` 在上传/下载之间也必须唯一，避免 cancel/pause 命中不确定；cancel 会释放下载 reader 或上传 writer，download pause 只返回最后 ACK 的安全恢复 offset，不会把已发送但尚未确认的窗口数据计入。

单流路径还支持活动 download cancel/pause、带 source fingerprint 的非 0 offset resume 请求，app-sandbox fresh/resume upload、fresh MediaStore upload、fresh SAF upload/resume，以及 MediaStore fresh-only upload resume 边界 probe；Mac harness 能在 transport close/timeout 后用 sidecar 对 download 和 app-sandbox/SAF upload 自动重试，真机脚本可用本地 frame proxy 注入首条传输连接断开并要求恢复成功；app-sandbox upload 对 ACK 丢失窗口会把 partial truncate 回 Mac 已确认 offset 后允许重发。Mac 产品异步层已通过本地 TCP 的原子文件下载、取消保留 partial、resume offset 竞态拒绝、四块窗口化上传和取消后 heartbeat 测试；真机混合流、产品 sidecar/recovery scheduler 和完整真机传输矩阵仍会继续收口。

## Provider Upload 语义

M1 upload 入口统一走 `OpenTransferRequest(direction=UPLOAD)`，Android 端只信任 `destination_path`：

- App sandbox：`dm://app-sandbox/<relative-file>` 写入 app 私有 `files/droidmatch-sandbox`。fresh upload 先删除同名 hidden partial，非 final close 保留 `.droidmatch-upload-part`；`upload --resume` 要求 partial 至少达到 requested offset，如果 partial 比 requested offset 更长，Android 会先 truncate 回 requested offset 以支持 ACK 丢失后的重发；final chunk 后替换目标文件。
- MediaStore：`dm://media-images/<display-name>` 和 `dm://media-videos/<display-name>` 是 fresh-only。Android 10+ 会插入 pending row，分别落在 `Pictures/DroidMatch/` 和 `Movies/DroidMatch/`；final chunk 后把 `IS_PENDING` 置 0，非 final close 或 open/write 失败会删除插入的 row。MediaStore upload resume 目前返回 `ERROR_CODE_UNSUPPORTED_CAPABILITY`，可用真机脚本的 `--upload-resume-unsupported-check` 记录这条边界。
- SAF：`dm://saf-<stable-id>/<display-name>` 写入授权 root，`dm://saf-<stable-id>/doc/<directory-token>/<display-name>` 写入已 listing 过的 SAF 目录 token。Android 只接受有写权限且支持 create 的目录；RPC fresh upload 会创建由 `transfer_id` 派生的 hidden partial 文档，非 final close 保留 partial；`upload --resume` 只在 partial 文档存在且长度等于 requested offset 时接受；final chunk 后 rename 成用户目标文件名。

`RpcTransferHandler` 会把 `OpenTransferRequest.transfer_id` 传到 provider upload 层；SAF partial document key 必须使用这颗稳定 transfer id，而不是从用户可见 display name 推导。

真机 smoke 的 `--cleanup-upload-destination` 只自动清理 app-sandbox 和 MediaStore 单段文件名目标。SAF 目标不自动删，等 delete/mutation 协议路径收口后再纳入自动清理。

本地用 `android/gradlew` 生成 protobuf Java lite classes、运行 Android JVM tests、编译 Android app / instrumentation test APK 并运行 lint：

```text
bash tools/check-m1-skeleton.sh
```

Android-only CI job 会设置 `DROIDMATCH_SKIP_SWIFT=1`，因为 Mac harness 已由独立 Swift job 覆盖。

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
cd android
ANDROID_SERIAL=<serial> ./gradlew --no-daemon :app:connectedDebugAndroidTest
```

debug APK 安装后，启动器里的 DroidMatch 图标会打开授权入口。真机 smoke 仍用 debug harness Activity 启动 Android 端 endpoint：

```text
adb shell am start -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity --ei port 39001
```

也可以用一键脚本完成安装、launcher 入口验证、debug harness 启动、ADB forward 和 `m1-smoke`：

```text
tools/run-m1-device-smoke.sh --serial <serial>
```

传入 `--handshake-attempts 20 --min-handshake-passes 19 --list-path dm://media-images/` 可记录 handshake 稳定性和首个目录 listing 耗时；传入 `--list-expect-error-path <dm-path> --list-expect-error-code <code>` 可记录 listing 预期失败映射；传入 `--source-path <dm-path> --resume-check` 时，脚本会先做 intentional partial download，再用 `download --resume` 验证非 0 offset 恢复；传入 `--download-retry-on-transport-loss` 可让 resume/full download 在 transport close/timeout 后用 sidecar 自动重试一次，传入 `--download-retry-fault-check` 可注入本地 proxy 断线并要求 `recovered=true`；传入 `--upload-source <local-file> --upload-destination-path dm://app-sandbox/<name> --upload-resume-check` 时，脚本会先做 intentional partial upload，再用 `upload --resume` 验证 app-sandbox upload 恢复，destination 也可以换成 writable `dm://saf-.../<name>`；传入 `--upload-retry-on-transport-loss` 可让 app-sandbox/SAF resume/full upload 在已写入 sidecar 的边界自动重试一次，传入 `--upload-retry-fault-check` 可注入本地 proxy 断线并要求 `recovered=true`，app-sandbox 目标还可用 `--upload-retry-ack-loss-check` 丢弃首个 ACK 并验证 partial truncate/replay；fresh upload 的 destination 也可以是 `dm://media-images/<name>` / `dm://media-videos/<name>`；对 MediaStore fresh-only 目标可加 `--upload-resume-unsupported-check` 验证非 0 offset open 被拒绝；`--cleanup-upload-destination` 会清理 app-sandbox 或 MediaStore upload 目标；100MiB 矩阵运行建议加 `--chunk-size-bytes 1048576 --min-download-mib-per-second 20`，脚本会解析 harness 输出的 elapsed/throughput 并写入日志，upload 也支持 `--min-upload-mib-per-second <mibps>`。脚本默认会把脱敏结果写入 `fixtures/m1-runs/`。如果只想临时排查，可加 `--no-result-log`。

这个 Activity 会保持屏幕唤醒并启动 `ForegroundConnectionService`。在部分国产 OEM 设备上，仅用后台前台服务启动后，app 线程可能进入 freezer，导致 ADB forward 连接进入 socket 队列但 Java `accept()` 不运行；debug harness Activity 是当前真机 smoke 的推荐启动方式。

当前 ADB 路径继续声明 `dataSync` foreground-service type：Android app 只接收 ADB forward 后的 loopback TCP，并没有持有 `connectedDevice` 在 Android 14+ 要求的 Bluetooth/UWB grant、网络状态权限或 `UsbManager.requestPermission()` 产生的 USB grant。为绕开 6 小时限制而声明并不满足前置条件的 `connectedDevice` 会在新系统上触发 `SecurityException`。Android 15 在 app 持续处于后台时会把所有 `dataSync` service 的总运行时间限制为每 24 小时 6 小时；达到限制后 `onTimeout()` 会关闭 endpoint 并停止 service。未来 AOA transport 真正通过 `UsbManager` 获得 accessory permission 时，再为该 transport 增加 `connectedDevice` type。

Mac 端通过 ADB forward 连接这个 endpoint 后，应跑 `m1-smoke` 验证同连接 handshake、heartbeat 和 control-plane RPC，再用 `list-dir` 取一个文件 logical path，并用 `download-cancel` / `download-pause` / `download` / `upload` 验证传输控制、多 chunk 下载、app-sandbox 上传、fresh MediaStore 上传和 fresh SAF 上传。
