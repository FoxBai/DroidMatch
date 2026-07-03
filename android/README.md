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

- `ForegroundConnectionService`：创建前台服务通知，并按 intent action 启动 ADB endpoint。
- `AdbEndpoint`：监听 debug harness 指定端口，只接受 loopback 客户端，设置 handshake/idle timeout，并把连接交给 dispatcher。
- `FramedIo`：读写 `uint32_be length + payload` frame，最大 4 MiB。
- `RpcDispatcher`：同一 session 先处理 `ClientHello`，再处理 `HeartbeatRequest`、`DeviceInfoRequest`、`ListDirRequest`、`OpenTransferRequest(download)` 多 chunk 发送、`OpenTransferRequest(upload)` app-sandbox/MediaStore/SAF 多 chunk 接收、download resume source fingerprint 校验、`TransferChunk` / `TransferChunkAck`、`CancelTransferRequest`、`PauseTransferRequest` 和 `DiagnosticsRequest`。
- `AndroidDeviceInfoProvider`：返回设备型号、Android 版本、SDK、数据分区容量、电量和 M1 权限状态。
- `DiagnosticsActivity`：作为 M1 最小授权入口，打开系统目录选择器并持久化 SAF tree URI 权限。
- `DmFileProvider`：提供 M1 `dm://roots/` 虚拟根目录，通过 MediaStore 列出 `dm://media-images/` / `dm://media-videos/`，列出 app-owned `dm://app-sandbox/` 和已授权 `dm://saf-.../` root 的首层/子目录内容，并能从 MediaStore/app sandbox/SAF file logical path 打开 download reader，优先用 seekable provider file descriptor 定位 resume offset，失败时回退到顺序 stream，且跨 chunk 复用同一个 provider reader；app-sandbox upload 写入 hidden partial file，非 final close 后保留 partial，final chunk 后替换目标文件；fresh MediaStore upload 通过 `ContentResolver.insert` 写入 Pictures/Movies 下的 DroidMatch collection，fresh SAF upload 通过 `DocumentsContract.createDocument` 写入有写权限的 SAF 目录，非 final close 会删除未完成文档。
- `PermissionStateProvider` / `DiagnosticsReporter`：提供早期权限和诊断状态，诊断计数器有 JVM 并发测试覆盖。
- Gradle app skeleton：可构建 debug APK，包名为 `app.droidmatch`，代码 namespace 为 `app.droidmatch.m1`。
- Android protobuf codegen：Gradle 从根目录 `proto/` 生成 `app.droidmatch.proto.v1` Java lite classes。
- launcher 入口：安装后启动器中显示 DroidMatch 图标，打开 `DiagnosticsActivity` 做通知/SAF 授权。
- debug harness overlay：debug APK 暴露 `DebugHarnessActivity` 和 service start 入口，便于用 `adb shell am ...` 启动真机 smoke；release manifest 仍不导出 service。

当前支持 download 方向的 receiver-paced 单流 open/chunk/ack smoke、活动 download cancel/pause、带 source fingerprint 的非 0 offset resume 请求，app-sandbox fresh/resume upload、fresh MediaStore upload，以及 fresh SAF upload；SAF upload resume、多流调度、自动断线恢复队列和完整真机传输矩阵仍会继续收口。

## Provider Upload 语义

M1 upload 入口统一走 `OpenTransferRequest(direction=UPLOAD)`，Android 端只信任 `destination_path`：

- App sandbox：`dm://app-sandbox/<relative-file>` 写入 app 私有 `files/droidmatch-sandbox`。fresh upload 先删除同名 hidden partial，非 final close 保留 `.droidmatch-upload-part`，`upload --resume` 只在 partial 长度等于 requested offset 时接受，final chunk 后替换目标文件。
- MediaStore：`dm://media-images/<display-name>` 和 `dm://media-videos/<display-name>` 是 fresh-only。Android 10+ 会插入 pending row，分别落在 `Pictures/DroidMatch/` 和 `Movies/DroidMatch/`；final chunk 后把 `IS_PENDING` 置 0，非 final close 或 open/write 失败会删除插入的 row。MediaStore upload resume 目前返回 `ERROR_CODE_UNSUPPORTED_CAPABILITY`。
- SAF：`dm://saf-<stable-id>/<display-name>` 写入授权 root，`dm://saf-<stable-id>/doc/<directory-token>/<display-name>` 写入已 listing 过的 SAF 目录 token。Android 只接受有写权限且支持 create 的目录；非 final close 删除新建文档。SAF upload resume 目前返回 `ERROR_CODE_UNSUPPORTED_CAPABILITY`。

真机 smoke 的 `--cleanup-upload-destination` 只自动清理 app-sandbox 和 MediaStore 单段文件名目标。SAF 目标不自动删，等 delete/mutation 协议路径收口后再纳入自动清理。

本地用 `android/gradlew` 生成 protobuf Java lite classes、运行 Android JVM tests、编译 Android app 并运行 lint：

```text
bash tools/check-m1-skeleton.sh
```

Android-only CI job 会设置 `DROIDMATCH_SKIP_SWIFT=1`，因为 Mac harness 已由独立 Swift job 覆盖。

也可以单独构建 APK：

```text
cd android
./gradlew --no-daemon :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

debug APK 安装后，启动器里的 DroidMatch 图标会打开授权入口。真机 smoke 仍用 debug harness Activity 启动 Android 端 endpoint：

```text
adb shell am start -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity --ei port 39001
```

也可以用一键脚本完成安装、launcher 入口验证、debug harness 启动、ADB forward 和 `m1-smoke`：

```text
tools/run-m1-device-smoke.sh --serial <serial>
```

传入 `--handshake-attempts 20 --min-handshake-passes 19 --list-path dm://media-images/` 可记录 handshake 稳定性和首个目录 listing 耗时；传入 `--source-path <dm-path> --resume-check` 时，脚本会先做 intentional partial download，再用 `download --resume` 验证非 0 offset 恢复；传入 `--upload-source <local-file> --upload-destination-path dm://app-sandbox/<name> --upload-resume-check` 时，脚本会先做 intentional partial upload，再用 `upload --resume` 验证 app-sandbox upload 恢复；fresh upload 的 destination 也可以是 `dm://media-images/<name>` / `dm://media-videos/<name>` 或 writable `dm://saf-.../<name>`；`--cleanup-upload-destination` 会清理 app-sandbox 或 MediaStore upload 目标。脚本默认会把脱敏结果写入 `fixtures/m1-runs/`。如果只想临时排查，可加 `--no-result-log`。

这个 Activity 会保持屏幕唤醒并启动 `ForegroundConnectionService`。在部分国产 OEM 设备上，仅用后台前台服务启动后，app 线程可能进入 freezer，导致 ADB forward 连接进入 socket 队列但 Java `accept()` 不运行；debug harness Activity 是当前真机 smoke 的推荐启动方式。

Mac 端通过 ADB forward 连接这个 endpoint 后，应跑 `m1-smoke` 验证同连接 handshake、heartbeat 和 control-plane RPC，再用 `list-dir` 取一个文件 logical path，并用 `download-cancel` / `download-pause` / `download` / `upload` 验证传输控制、多 chunk 下载、app-sandbox 上传、fresh MediaStore 上传和 fresh SAF 上传。
