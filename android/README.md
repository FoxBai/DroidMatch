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

当前骨架不依赖 Gradle；本地先用 Android SDK 的 `android.jar` 编译 Java service skeleton：

```text
bash tools/check-m1-skeleton.sh
```
