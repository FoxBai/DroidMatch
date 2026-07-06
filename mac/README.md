# DroidMatch Mac 端

这里是 DroidMatch Mac 端实现目录。

M1 起点：

- 先构建命令行或最小验证壳，不构建完整产品 UI。
- 验证 ADB 发现、授权、forward、握手和重连。
- 实现 `RpcEnvelope` 的 length-prefixed Protobuf 编解码。
- 跑通 `DeviceInfoRequest`、`ListDirRequest`、`OpenTransfer`、pause、cancel 和 resume。
- 收集 M1 需要的诊断日志和性能指标。

M0 规格已经收口，见 `docs/m0-closeout.md`、`docs/architecture.md` 和 `docs/protocol.md`。

M1 暂时把 Core、Transport、Protocol 和 Diagnostics 骨架合并在 `DroidMatchCore` target 内；M1 通过后再按 `docs/architecture.md` 拆成更细 target。

## 当前已实现

- `AdbClient`：选择 adb 路径、解析 `adb devices -l`、创建/list/remove adb forward。
- `FrameCodec` / `FrameReader`：4 MiB 上限的 length-prefixed frame 编解码。
- `FramedTcpClient` / `FramedTcpSession`：基于 Network.framework 做一次或同连接多次 TCP frame round-trip。
- `HandshakeSmokeClient`：构造 `ClientHello`，通过 framed TCP 发送，并校验 `ServerHello`。
- `M1SmokeClient` / `RpcControlClient`：在同一连接上连续跑 handshake、heartbeat、device info、`dm://roots/` root listing、diagnostics，并能打开 download transfer、逐块校验 CRC32、回 ACK 或发 cancel/pause；也能把本地文件按窗口化 chunks upload（`UploadWindow`，最多 4 chunk / 2MiB 在途）到 Android app sandbox、MediaStore collection 或 writable SAF root，并从 app-sandbox 接受的 upload offset 继续发送。
- `droidmatch-harness`：提供 adb/path/devices/frame/forward/framed-echo/handshake-smoke/m1-smoke/list-dir/list-dir-expect-error/download-once/download-cancel/download-pause/download/upload 命令。

Swift protobuf codegen 已接入，`m1-smoke` 是当前 Android endpoint 的正式 M1 control-plane 联通命令，会在同一连接内验证 handshake、heartbeat、device info、root listing 和 diagnostics。`handshake-smoke` 可单独排查 hello 阶段；`framed-echo` 仍保留给本地 echo server 或旧 placeholder endpoint 做 frame 层排查。

## 命令

本地验证：

```text
swift test --package-path mac
swift run --package-path mac droidmatch-harness frame-self-test
swift run --package-path mac droidmatch-harness devices
```

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
```

当前 download 是窗口化 receiver-paced 单流路径：Mac 仍逐块校验 CRC32、写入并 ACK，Android 在第一个 ACK 后按协议上限保持最多 4 个 chunk 或 2MiB in-flight。upload 仍是单流，但现已使用对称的 `UploadWindow`（`mac/Sources/DroidMatchCore/UploadWindow.swift`）：Mac 发送侧维持最多 4 个 chunk / 2MiB 在途，单线程内连续发送填满窗口、阻塞收一个 ACK、再补发，把吞吐从 `chunkSize / RTT`（stop-and-wait 实测 11.49 MiB/s）提升到已归档的 33.51 MiB/s Slot D 真机结果；Android 端 `handleTransferChunk` 只校验 chunk 顺序到达，无需改动即可接受窗口化上传。下载中的数据写入目标文件旁边的 `.droidmatch-part`，完整成功后才原子提交到目标路径；`download-cancel` 会在首块后发 `CancelTransferRequest` 验证活动传输可释放；`download-pause` 会在首块后发 `PauseTransferRequest` 并验证可恢复 offset；`download --resume` 会从这个 part 文件续写，并依赖 `.droidmatch-transfer.json` sidecar 里的 Android source fingerprint；app-sandbox 和 SAF `upload --stop-after-bytes` 会留下本地 `.droidmatch-upload-transfer.json` sidecar，随后 `upload --resume` 会请求该 offset 并续传。`download --retry-on-transport-loss` 会在 transport close/timeout 或远端 `transportLost`/`timeout` 后重新建 session、重新 handshake，并用 sidecar 自动重试；默认行为与历史一致（最多重试一次），加 `--max-retry-attempts N` 可开启完整恢复队列（多次重试 + 指数退避，`--retry-backoff-ms M` 控制基准退避，默认 500ms，退避上限 30s，无抖动以便真机日志复现）；`upload --retry-on-transport-loss` 只允许 app-sandbox/SAF 目标，并从已写入 sidecar 的 transfer id / next offset 边界继续，同样支持 `--max-retry-attempts` / `--retry-backoff-ms`。`tools/run-m1-device-smoke.sh --download-retry-fault-check` / `--upload-retry-fault-check` 会把 harness 临时接到 `tools/m1-fault-proxy.py`，在第一条传输连接的第三个 server frame 后断开连接，并要求最终输出 `recovered=true`；app-sandbox-only 的 `--upload-retry-ack-loss-check` 会读到但不转发首个 upload ACK，验证 Android partial 回退后 Mac 可重发。fresh `upload` 目前支持 `dm://app-sandbox/<file>`、`dm://media-images/<file>`、`dm://media-videos/<file>` 和 writable `dm://saf-.../<file>` / `dm://saf-.../doc/<directory-token>/<file>`；SAF upload resume 使用 Android 端 transfer-id hidden partial 文档；`upload-open-expect-error` 用于验证 MediaStore fresh-only provider 对非 0 offset upload open 返回预期错误，不会发送文件 chunk。恢复队列核心 `RecoveryPolicy` 位于 `mac/Sources/DroidMatchCore/RecoveryPolicy.swift`，upload 窗口核心 `UploadWindow` 位于 `mac/Sources/DroidMatchCore/UploadWindow.swift`，二者均为纯逻辑、可单测，由 harness 的 download/upload 循环驱动。下一步是预热列表 gate、Slot A/C 设备矩阵、权限撤销/USB 拔插异常场景、多流调度和真机 SAF 上传矩阵。

真机一键脚本适合记录可复现 smoke，尤其是需要安装 debug APK、启动 `DebugHarnessActivity` 和清理测试上传目标时：

```text
tools/run-m1-device-smoke.sh --upload-source /tmp/droidmatch-upload.jpg --upload-destination-path dm://media-images/droidmatch-upload.jpg --upload-resume-unsupported-check --min-upload-bytes 1 --cleanup-upload-destination
```

`--upload-resume-unsupported-check` 会先请求 offset 1 的 upload open，并要求 Android 返回 `unsupportedCapability`，只适合 MediaStore 这类 fresh-only provider 的边界记录。SAF 目标应使用 `--upload-resume-check` 验证 partial/resume。需要记录 sidecar-backed transport retry 时，下载加 `--download-retry-on-transport-loss`，app-sandbox/SAF 上传加 `--upload-retry-on-transport-loss`；默认保持历史单次重试，额外传 `--max-retry-attempts N` / `--retry-backoff-ms M` 可在真机日志中记录多尝试恢复队列策略。需要真实注入 Mac 侧连接断开时，分别使用 `--download-retry-fault-check` 和 `--upload-retry-fault-check`；需要覆盖 Android 已写入但 ACK 没到 Mac 的 app-sandbox 窗口时，使用 `--upload-retry-ack-loss-check`。100MiB download 矩阵运行应加 `--chunk-size-bytes 1048576 --min-download-mib-per-second 20`，harness 输出会包含 `elapsed_ms` 和 `throughput_mib_per_sec`，脚本会写入日志并在低于阈值时失败；upload 可用 `--min-upload-mib-per-second <mibps>` 做同类记录。MediaStore upload 不支持这个上传重试路径。`--cleanup-upload-destination` 对 app-sandbox 用 `run-as` 删除私有文件；对 MediaStore 只清理 `dm://media-images/<name>` / `dm://media-videos/<name>` 这种 root 下单段文件名，并在 Android 10+ 限定到 DroidMatch 写入的 `Pictures/DroidMatch/` 或 `Movies/DroidMatch/`。SAF upload smoke 不自动清理，因为当前协议还没有 delete/mutation 路径。
