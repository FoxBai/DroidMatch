# DroidMatch

DroidMatch 是一款面向 macOS 的现代 Android 设备管理客户端。

项目目标是构建一个 Apple Silicon 原生、稳定、快速、可诊断的 HandShaker 现代替代品。DroidMatch 复刻的是有价值的用户工作流，而不是旧品牌、旧视觉资产、旧二进制实现或旧 UI。

详见 [docs/handshaker-relationship.md](docs/handshaker-relationship.md)：DroidMatch 与 HandShaker 的关系是工作流替代，不是代码、品牌、资产或二进制延续。

## 项目方向

- 本地优先，USB 优先，默认零云依赖。
- Mac 端与 Android 端双端重写。
- ADB 是稳定兼容路径。
- AOA 是低门槛消费级连接路径，但必须由 PoC 数据验证。
- v1.0 聚焦连接、文件、基础媒体浏览、传输恢复、诊断、签名与分发。
- 屏幕镜像、通知镜像、剪贴板同步、文件夹订阅和 Wi-Fi 是 v1.5+ 候选能力。

## 当前状态

M0 规格已经收口，结论见 [docs/m0-closeout.md](docs/m0-closeout.md)。当前仓库处在 M1 harness 骨架阶段：

- Mac 端已有 SwiftPM package、ADB discovery/forward helper、length-prefixed frame codec、同连接 TCP control-plane client 和命令行 harness。
- Android 端已有前台服务、localhost ADB endpoint、framed IO、`ClientHello`/`ServerHello`、`DeviceInfoRequest`、`ListDirRequest` root/media/SAF listing、`OpenTransferRequest(download)` 多 chunk 读取和 `DiagnosticsRequest` dispatcher、权限状态和诊断骨架。
- Android 目录已有最小 Gradle app 工程，可构建 debug APK，并会从 `proto/v1/*.proto` 生成 Java lite protobuf classes。
- Protocol schema 已能通过 `protoc` 编译；Android Java 和 Swift protobuf 生成代码都已接入。
- 当前 Mac harness 已能通过 `m1-smoke` 在同一连接上连续跑 handshake、device info、`dm://roots/` root listing 和 diagnostics；也可以用 `list-dir` 手动验证 `dm://media-images/`、`dm://media-videos/` 和持久化后的 `dm://saf-.../` root，并用 `download` 打开下载传输、逐块校验 CRC32、ACK 后写入本地文件。`download --resume` 已能用 sidecar 里的 source fingerprint 请求非 0 offset 恢复；upload、pause/cancel、自动断线恢复队列和多流调度仍是下一步。

给人和 agent 的接手顺序：

1. 先读这个 README，确认当前阶段和占位边界。
2. 再读 [docs/m0-closeout.md](docs/m0-closeout.md)、[docs/protocol.md](docs/protocol.md)、[docs/protocol-runtime.md](docs/protocol-runtime.md)、[docs/path-model.md](docs/path-model.md)。
3. Mac 端接手看 [mac/README.md](mac/README.md)，Android 端接手看 [android/README.md](android/README.md)。
4. 每次推送前更新相关 README，让下一位接手者不用从 commit diff 里猜项目状态。

## 仓库结构

```text
DroidMatch/
├── android/
├── mac/
├── proto/
├── docs/
├── tools/
├── fixtures/
└── .github/workflows/
```

## 验证命令

规格和骨架 gate：

```text
bash tools/check-m0.sh
bash tools/check-proto.sh
bash tools/check-m1-skeleton.sh
```

`check-m1-skeleton.sh` 会优先使用 `android/gradlew` 运行 Android JVM tests、构建 debug APK 并运行 lint；CI 会强制执行这一步。

Mac harness 本地命令：

```text
swift run --package-path mac droidmatch-harness adb-path
swift run --package-path mac droidmatch-harness devices
swift run --package-path mac droidmatch-harness frame-self-test
```

Android endpoint 可用后，Mac 端用下面两步做 M1 control-plane smoke test：

```text
adb shell am start -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity --ei port <android-port>
swift run --package-path mac droidmatch-harness forward --serial <serial> --remote-port <android-port>
swift run --package-path mac droidmatch-harness m1-smoke --port <local-port>
swift run --package-path mac droidmatch-harness list-dir --port <local-port> --path dm://media-images/
swift run --package-path mac droidmatch-harness list-dir --port <local-port> --path dm://saf-<stable-id>/
swift run --package-path mac droidmatch-harness download-once --port <local-port> --source-path dm://media-images/media/<id>
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin --resume
```

`handshake-smoke` 可单独排查 hello 阶段；`framed-echo` 只适用于本地或旧 placeholder echo endpoint。
Android APK 安装后会在启动器中显示 DroidMatch 图标，入口是授权用的 `DiagnosticsActivity`。`DebugHarnessActivity` 是 debug APK 专用入口，用于真机 smoke 时保持 Android endpoint 前台可运行；release manifest 仍不导出服务入口。
设备已通过 `adb devices -l` 授权后，可以用一键脚本安装 debug APK、验证 launcher 入口、启动 debug harness、创建 adb forward 并运行 `m1-smoke`：

```text
tools/run-m1-device-smoke.sh --serial <serial>
```

## 授权协议

DroidMatch 使用 Mozilla Public License 2.0（MPL-2.0）授权。详见 [LICENSE](LICENSE)。

## M0 回顾

M0 是规格阶段。只有当下面的问题都能被文档清楚回答时，M0 才算完成：

- DroidMatch v1.0 做什么、不做什么？
- Mac、Android、协议和传输层的模块边界是什么？
- ADB 与 AOA 如何发现设备、握手、重连和失败？
- 协议如何处理版本协商、请求取消和大文件传输？
- Android 权限不足时如何降级？
- M1 如何在真机上验收？

从 [docs/m0-checklist.md](docs/m0-checklist.md) 开始。
