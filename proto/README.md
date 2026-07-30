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
- `DiscardUploadPartialRequest` 是与活动 transfer cancel 分离的认证清理 RPC；
  它用 destination/transfer/expected-size 精确定位 App Sandbox 或 SAF 私有 partial，
  缺失视为幂等成功，且永不删除最终目标。

## Code Generation

Android uses the Gradle protobuf plugin to generate Java lite classes from this directory:

```text
bash tools/run-android-gradle.sh :app:generateDebugProto
```

Generated files are build artifacts under `android/app/build/generated/` and are not committed.

Swift protobuf files are generated into `mac/Sources/DroidMatchCore/Generated/` and committed:

```text
bash tools/generate-swift-proto.sh
```

With `PROTOC_GEN_SWIFT` unset, the generator first delegates to
`tools/bootstrap-swift-protobuf.sh`. The bootstrap requires the exact
`mac/Package.resolved` SwiftProtobuf revision, a clean checkout before and after
the build, and an identity/hash-verified atomic plugin install. Set
`PROTOC_GEN_SWIFT=/path/to/protoc-gen-swift` to bypass that bootstrap with an
explicit executable; an explicitly empty value also bypasses it and fails
closed.

## Compatibility Baseline

`v1/compatibility-baseline.json` is generated from the reviewed v1
`FileDescriptorSet`; it is not a second hand-authored schema. The ordinary gate
compiles the current protos and requires an exact baseline match:

```text
bash tools/check-proto.sh
```

CI additionally compares the PR or push base commit's accepted baseline with the
candidate baseline, so the candidate may add fields, enum values, messages,
files, and imports but may not delete or weaken prior identity. The compiled
descriptor must contain its complete import closure, and an existing message
cannot gain a proto2 `required` field. Removing,
renaming, renumbering, moving a declaration between source files, or changing
accepted wire/API, presence/oneof, selected-option, or import-mode identity
fails. After both platforms and protocol documentation accept an additive
change, generate a candidate baseline at a new path, review its diff, and replace
the committed baseline as part of that same protocol change:

```text
droidmatch_proto_tmp="$(mktemp -d)"
protoc --proto_path=proto \
  --include_imports \
  --descriptor_set_out="${droidmatch_proto_tmp}/droidmatch-v1.pb" \
  proto/v1/*.proto
python3 tools/check_proto_compatibility.py \
  --descriptor "${droidmatch_proto_tmp}/droidmatch-v1.pb" \
  --write-baseline "${droidmatch_proto_tmp}/compatibility-baseline.json"
diff -u proto/v1/compatibility-baseline.json \
  "${droidmatch_proto_tmp}/compatibility-baseline.json"
```

Do not overwrite the reviewed baseline before inspecting that diff, and never
update it only to make a breaking check pass.
