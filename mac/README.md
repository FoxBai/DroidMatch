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
- `M1SmokeClient` / `RpcControlClient`：在同一连接上连续跑 handshake、heartbeat、device info、`dm://roots/` root listing、diagnostics，并能打开 download transfer、逐块校验 CRC32、回 ACK。
- `droidmatch-harness`：提供 adb/path/devices/frame/forward/framed-echo/handshake-smoke/m1-smoke/list-dir/download-once/download 命令。

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
```

SAF 目录列表 smoke：

1. 在 Android 端点击 DroidMatch 前台服务通知，选择一个目录并授权。
2. 运行 `m1-smoke` 或 `list-dir --path dm://roots/`，从 root listing 里取 `dm://saf-.../` 路径。
3. 验证授权目录：

```text
swift run --package-path mac droidmatch-harness list-dir --port <local-port> --path dm://saf-<stable-id>/
```

下载 smoke：

```text
swift run --package-path mac droidmatch-harness download-once --port <local-port> --source-path dm://media-images/media/<id>
swift run --package-path mac droidmatch-harness download-once --port <local-port> --source-path dm://saf-<stable-id>/<opaque-file-id>
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://saf-<stable-id>/<opaque-file-id> --destination /tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin --resume
```

当前 download 是 receiver-paced、单流、一次只放行一个 chunk 的 M1 smoke 路径。下载中的数据写入目标文件旁边的 `.droidmatch-part`，完整成功后才原子提交到目标路径；`--resume` 会从这个 part 文件续写，并依赖 `.droidmatch-transfer.json` sidecar 里的 Android source fingerprint。下一步是补 upload、pause/cancel、自动断线恢复队列、多流调度和真机 100MB 传输矩阵。
