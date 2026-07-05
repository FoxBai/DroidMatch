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
- Android 端已有前台服务、localhost ADB endpoint、framed IO、`ClientHello`/`ServerHello`、`HeartbeatRequest`、`DeviceInfoRequest`、`ListDirRequest` root/media/SAF/app-sandbox listing、`OpenTransferRequest(download)` 多 chunk 读取和 `DiagnosticsRequest` dispatcher、权限状态和诊断骨架。
- Android 目录已有最小 Gradle app 工程，可构建 debug APK，并会从 `proto/v1/*.proto` 生成 Java lite protobuf classes。
- Protocol schema 已能通过 `protoc` 编译；Android Java 和 Swift protobuf 生成代码都已接入。
- 当前 Mac harness 已能通过 `m1-smoke` 在同一连接上连续跑 handshake、heartbeat、device info、`dm://roots/` root listing 和 diagnostics；也可以用 `list-dir` 手动验证 `dm://media-images/`、`dm://media-videos/`、`dm://app-sandbox/` 和持久化后的 `dm://saf-.../` root，并用 `download` 打开下载传输、逐块校验 CRC32、ACK 后写入本地文件。`download-cancel` / `download-pause` 会在收首块后发送对应 transfer control request 并验证响应；`download --resume` 已能用 sidecar 里的 source fingerprint 请求非 0 offset 恢复；`upload` / `upload --resume` 已能把本地文件按 receiver-paced chunks 写入 Android `dm://app-sandbox/`，并从 Android 保留的 hidden partial file 继续写；fresh `upload` 也能写入 MediaStore 图片/视频 collection，以及有写权限的 SAF root 或 SAF 目录 token；SAF `upload --resume` 使用 transfer-id 派生的 partial 文档续传；`download --retry-on-transport-loss` 和 app-sandbox/SAF `upload --retry-on-transport-loss` 可在 transport close/timeout 后用已落盘 sidecar 自动重连并重试，默认行为与历史一致（最多重试一次），加 `--max-retry-attempts N` 可开启完整恢复队列（多次重试 + 指数退避，`--retry-backoff-ms M` 控制基准退避），真机脚本还能通过 `tools/m1-fault-proxy.py` 注入首条传输连接断开并要求 `recovered=true`；app-sandbox upload 可在 ACK 丢失后把 partial 回退到 Mac 已确认 offset 再重发；`upload-open-expect-error` 可记录 MediaStore fresh-only provider 对非 0 offset upload open 的 unsupported 边界，`list-dir-expect-error` 可记录 listing 预期错误码边界，`--media-permission-revoked-check` 可记录 media 权限撤销后的 listing 边界，`download-open-expect-error` 可记录 download transfer open 预期错误码边界。多流调度和真机 SAF 上传矩阵仍是下一步。

给人和 agent 的接手顺序：

1. 先读这个 README，确认当前阶段和占位边界。
2. 新开发者完整入门看 [docs/developer-onboarding.md](docs/developer-onboarding.md)。
3. 再读 [docs/m0-closeout.md](docs/m0-closeout.md)、[docs/protocol.md](docs/protocol.md)、[docs/protocol-runtime.md](docs/protocol-runtime.md)、[docs/path-model.md](docs/path-model.md)。
4. Mac 端接手看 [mac/README.md](mac/README.md) 和 [docs/mac-code-overview.md](docs/mac-code-overview.md)，Android 端接手看 [android/README.md](android/README.md) 和 [docs/android-code-overview.md](docs/android-code-overview.md)。
5. 真机测试按 [docs/m1-testing-guide.md](docs/m1-testing-guide.md) 运行完整 M1 退出门槛测试。
6. 每次推送前更新相关 README，让下一位接手者不用从 commit diff 里猜项目状态。

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

`check-m1-skeleton.sh` 默认同时跑 Mac Swift harness 和 Android skeleton；Android-only CI job 会设置 `DROIDMATCH_SKIP_SWIFT=1`，Swift 由独立 macOS job 覆盖。

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
swift run --package-path mac droidmatch-harness download-open-expect-error --port <local-port> --source-path dm://app-sandbox/missing.bin --expected-error-code notFound
swift run --package-path mac droidmatch-harness download-once --port <local-port> --source-path dm://media-images/media/<id>
swift run --package-path mac droidmatch-harness download-cancel --port <local-port> --source-path dm://media-images/media/<id>
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin --resume
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin --retry-on-transport-loss
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin --retry-on-transport-loss --max-retry-attempts 3 --retry-backoff-ms 500
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --stop-after-bytes 1
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --resume
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --retry-on-transport-loss
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --retry-on-transport-loss --max-retry-attempts 3 --retry-backoff-ms 500
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.jpg --destination-path dm://media-images/droidmatch-upload.jpg
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://saf-<stable-id>/droidmatch-upload.bin
```

`handshake-smoke` 可单独排查 hello 阶段；`framed-echo` 只适用于本地或旧 placeholder echo endpoint。
Android APK 安装后会在启动器中显示 DroidMatch 图标，入口是授权用的 `DiagnosticsActivity`。`DebugHarnessActivity` 是 debug APK 专用入口，用于真机 smoke 时保持 Android endpoint 前台可运行；release manifest 仍不导出服务入口。
设备已通过 `adb devices -l` 授权后，可以用一键脚本安装 debug APK、验证 launcher 入口、启动 debug harness、创建 adb forward 并运行 `m1-smoke`：

```text
tools/run-m1-device-smoke.sh --serial <serial>
```

传入 `--handshake-attempts 20 --min-handshake-passes 19 --list-path dm://media-images/` 可记录 handshake 稳定性和首个目录 listing 耗时；传入 `--list-expect-error-path <dm-path> --list-expect-error-code <code>` 可记录 listing 预期失败映射；传入 `--media-permission-revoked-check` 可撤销 media read 权限并要求 media root listing 返回 `permissionRequired`，然后恢复运行前授予的 media 权限；传入 `--download-open-expect-error-path <dm-path> --download-open-expect-error-code <code>` 可记录 download transfer open 预期失败映射；传入 `--source-path <dm-path> --resume-check` 时，脚本会先做一次 intentional partial download，再用同一 sidecar/fingerprint 跑 `download --resume`；传入 `--download-retry-on-transport-loss` 可让 resume/full download 在 transport close/timeout 后用 sidecar 自动重试（默认一次），`--max-retry-attempts N` 和 `--retry-backoff-ms M` 可把非默认恢复队列策略写进真机日志；传入 `--download-retry-fault-check` 会通过本地 frame proxy 切断第一条传输连接并要求 `recovered=true`；传入 `--source-path <dm-path> --cancel-check` / `--pause-check` 可记录首块后 `download-cancel` / `download-pause`；传入 `--upload-source <local-file> --upload-destination-path dm://app-sandbox/<name> --min-upload-bytes <bytes>` 可记录 app-sandbox upload，destination 也可换成 fresh-only 的 `dm://media-images/<name>` / `dm://media-videos/<name>` 或 writable `dm://saf-.../<name>`；`--upload-resume-unsupported-check` 会对 MediaStore fresh-only upload 目标先发非 0 offset open 并要求 Android 返回 `unsupportedCapability`；`--cleanup-upload-destination` 可清理 app-sandbox 和 MediaStore upload 目标；再加 `--upload-resume-check --upload-partial-bytes <bytes>` 可先做 intentional partial upload，再跑 app-sandbox 或 SAF `upload --resume`；传入 `--upload-retry-on-transport-loss` 可让 app-sandbox/SAF resume/full upload 在已写入 sidecar 的边界自动重试（默认一次），同样支持 `--max-retry-attempts N` / `--retry-backoff-ms M`；传入 `--upload-retry-fault-check` 会通过本地 frame proxy 注入断线并要求 `recovered=true`，传入 app-sandbox-only 的 `--upload-retry-ack-loss-check` 会丢弃首个 upload ACK 并验证 partial 回退重发；传入 `--prepare-app-sandbox-file dm-100mb-zero.bin --resume-check` 会在 app 私有 sandbox 里准备默认 100MiB 测试文件，并自动设置 source/list/min-byte gate；矩阵测速建议加 `--chunk-size-bytes 1048576 --min-download-mib-per-second 20` 断言 100MiB download throughput，upload 也可用 `--min-upload-mib-per-second <mibps>` 记录和断言。脚本默认会把脱敏后的真机结果写入 `fixtures/m1-runs/`；调试临时运行可加 `--no-result-log`。

开发时跑 upload smoke 的约定：

- `dm://app-sandbox/<name>` 支持 fresh、partial 和 resume；`--cleanup-upload-destination` 会用 `run-as app.droidmatch rm` 清理 app 私有测试文件。
- `dm://media-images/<name>` 和 `dm://media-videos/<name>` 目前只支持 fresh upload；Android 10+ 写入 `Pictures/DroidMatch/` 或 `Movies/DroidMatch/`，`--upload-resume-unsupported-check` 可把 non-zero offset 被拒绝这条边界写进真机日志，`--cleanup-upload-destination` 会用 MediaStore `content delete` 按 display name 和 relative path 清理。为了避免误删，脚本只自动清理 root 下单段文件名，且文件名不能包含单引号。
- `dm://saf-.../<name>` 和 `dm://saf-.../doc/<directory-token>/<name>` 支持 fresh、partial 和 resume；Android 用 `transfer_id` 生成隐藏 partial 文档，resume 时校验 partial 长度，final chunk 后 rename 成用户目标文件名。脚本不会自动清理 SAF 目标，因为协议还没有 delete/mutation smoke，不能安全地从用户选目录里移除文件。

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
