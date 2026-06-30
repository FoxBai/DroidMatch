# DroidMatch 协议

协议使用 Protobuf 作为 schema 语言。M0 阶段不应把所有传输路径都绑定到 gRPC。

基本原则：

- Protobuf 消息定义请求、响应、事件、错误和能力。
- `v1/rpc.proto` 定义 M1 顶层 envelope、payload type 注册表、请求取消消息。
- ADB TCP 通道后续可以按需要支持 gRPC 或 HTTP/2。
- AOA bulk 传输应先从轻量 frame 协议开始。
- 控制面和数据面必须保持可分离。
- M1 文件下载和上传统一走 `OpenTransferRequest` + `TransferChunk`，不再单独定义 `GetFile` / `PutFile`。
- M1 断点续传使用可选 `TransferFingerprint` 校验源文件是否变化。

## Code Generation

Android uses the Gradle protobuf plugin to generate Java lite classes from this directory:

```text
cd android
./gradlew --no-daemon :app:generateDebugProto
```

Generated files are build artifacts under `android/app/build/generated/` and are not committed. Swift protobuf code generation is not wired in yet.
