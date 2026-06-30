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
- `FramedTcpClient`：基于 Network.framework 做一次 TCP frame round-trip。
- `droidmatch-harness`：提供 adb/path/devices/frame/forward/framed-echo smoke test 命令。

Swift protobuf codegen 已接入，但还没有真正的 `ClientHello` / `ServerHello` handshake。`framed-echo` 只是为了验证 Mac frame client 能穿过 ADB forward 打到 Android echo dispatcher。

## 命令

本地验证：

```text
swift test --package-path mac
swift run --package-path mac droidmatch-harness frame-self-test
swift run --package-path mac droidmatch-harness devices
```

ADB forward：

```text
swift run --package-path mac droidmatch-harness forward --serial <serial> --remote-port <android-port>
```

如果省略 `--local-port`，harness 使用 `adb forward tcp:0 ...`，并打印 adb 分配的 `local_port`。

Raw framed echo：

```text
swift run --package-path mac droidmatch-harness framed-echo --port <local-port> --payload hello
swift run --package-path mac droidmatch-harness framed-echo --port <local-port> --hex 68656c6c6f
```

下一步是把 `framed-echo` 升级为真正的 handshake smoke test。
