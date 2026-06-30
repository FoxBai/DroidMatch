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
- `AdbEndpoint`：绑定 `127.0.0.1`，接受 socket，设置 handshake/idle timeout，并把连接交给 dispatcher。
- `FramedIo`：读写 `uint32_be length + payload` frame，最大 4 MiB。
- `RpcDispatcher`：当前是 raw frame echo placeholder，用于 M1 Mac harness 联通测试。
- `PermissionStateProvider` / `DiagnosticsReporter`：提供早期权限和诊断状态。
- Gradle app skeleton：可构建 debug APK，包名为 `app.droidmatch`，代码 namespace 为 `app.droidmatch.m1`。
- Android protobuf codegen：Gradle 从根目录 `proto/` 生成 `app.droidmatch.proto.v1` Java lite classes。

当前还没有 Swift protobuf 生成代码或真实 RPC 分发。启动服务和指定 Android 端口的真机流程会在下一轮 harness 工作中补齐。

本地先用 Android SDK 的 `android.jar` 编译 Java service skeleton，然后用 `android/gradlew` 构建 debug APK：

```text
bash tools/check-m1-skeleton.sh
```

也可以单独构建 APK：

```text
cd android
./gradlew --no-daemon :app:assembleDebug :app:lintDebug
```

Mac 端通过 ADB forward 连接这个 endpoint 后，应先跑 raw `framed-echo`，再升级到 protobuf handshake。
