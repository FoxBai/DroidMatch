# 开发者入门

[English](developer-onboarding.md) · [文档索引](README.md) ·
[贡献指南](../CONTRIBUTING.md)

DroidMatch 是一个处于 M1 阶段的 macOS Android 设备管理产品。Mac 原生 App 已经通过
可复用的 Core 和 Presentation 边界完成 serial 脱敏发现、可见配对、已配对认证、
文件/媒体浏览、结构化诊断和持久下载/上传。Android App 负责安全连接、信任、媒体权限
和 SAF 文件夹授权，不是另一个本地文件管理器。

当前还不是公开发行版本。开放的 ADB M1 阻塞项是 Slot A current-tip release 吞吐证据，
以及 Slot A/C/D 需要人工参与的产品 USB 插入证据。Developer ID 签名、公证和发布自动化
按当前决定暂缓。

## 本地快速开始

### 前置条件

- macOS 13 或更高版本
- Xcode 和 Swift 工具链
- JDK 17
- Android SDK Platform 36、Build Tools 36.0.0 和 platform-tools/ADB
- 仓库内 Gradle wrapper，以及获取其声明依赖所需的网络环境

克隆仓库并检查工具链：

```bash
git clone https://github.com/FoxBai/DroidMatch.git
cd DroidMatch
bash tools/check-env.sh --all
```

构建并测试 Mac 端：

```bash
bash tools/run-swift-tests.sh
tools/build-mac-app.sh
open mac/.build/app/DroidMatch.app
```

构建并测试 Android 端：

```bash
bash tools/run-android-gradle.sh \
  :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

这个仓库入口会验证并把解析到的 JDK 17 与 Android SDK 同时传给 Gradle；它不依赖
`check-env.sh` 子进程无法保留的 export，也无需提交绑定本机的
`android/local.properties`。

以上命令只执行本地构建和测试，不代表获准修改已连接的 Android 设备。

## 修改代码前阅读

按照任务选择最小阅读路径：

1. [M1 状态](m1-status.md)：已实现行为、阻塞项和有效证据。
2. [架构](architecture.md)：职责和依赖方向。
3. [协议](protocol.md)、[协议运行时](protocol-runtime.md)、[路径模型](path-model.md)
   和[安全模型](security-model.md)：跨端共享边界。
4. [Mac 代码导览](mac-code-overview.md)或
   [Android 代码导览](android-code-overview.md)：平台实现。
5. 修改 gate 或运行真机前阅读 [CI/CD](ci-cd.md)和
   [M1 测试指南](m1-testing-guide-zh.md)。
6. 交接、事故处理或判断发布前阅读[维护者手册](maintainer-runbook.md)。

包含历史文档在内的完整地图见[文档索引](README.md)。

## 常见任务

### 运行仓库门禁

迭代时运行最窄检查，交接前运行完整受影响门禁：

```bash
bash tools/check-m0.sh
python3 tools/check-source-size.py
bash tools/check-proto.sh
python3 tools/check-doc-links.py
bash tools/check-m1-run-logs.sh
bash tools/check-m1-skeleton.sh
```

### 重新生成 protobuf

`proto/v1/*.proto` 是跨端 wire 唯一事实源。不要手改生成的 Swift 或 Java 文件。

```bash
bash tools/generate-swift-proto.sh
bash tools/run-android-gradle.sh :app:generateDebugProto
```

未设置 `PROTOC_GEN_SWIFT` 时，Swift 生成脚本会引导 lockfile 固定的工具链；显式 override
必须指向真实可执行文件。

### 在无设备情况下查看 harness

```bash
swift run --package-path mac droidmatch-harness --help
tools/quick-test-scenarios.sh help
```

查看 scenario 帮助是只读操作。实际运行 scenario 可能安装 APK、创建测试数据、修改权限
并发布结果日志。

## 真机安全

`adb devices -l` 只是只读可见性检查，不代表获准安装、配对、传输、修改权限或清理。

运行真机脚本前：

1. 明确选择可丢弃或已备份的设备及精确 serial。
2. 记录所有预期的设备/Mac 写入和清理计划。
3. 确认流程是否需要人工批准或拔线/重连操作。
4. 使用文档规定的版本化 runner profile。
5. 归档前验证并脱敏结果。

遵循 [M1 测试指南](m1-testing-guide-zh.md)和[设备矩阵](m1-device-matrix.md)。本地通过、
复用 APK、dirty source 或 diagnostic-only fixture 都不能满足真机 gate。

## 核心概念

### 依赖方向

产品 UI 依赖 domain/session/transfer 接口。Transport 拥有字节和连接状态；RPC 拥有
envelope、ID 和响应匹配；transfer 拥有 checkpoint、重试/恢复、完整性和原子发布。
Android provider 规则留在 provider 接口后面，而不是放进 `RpcDispatcher`。

### 逻辑路径

DroidMatch 不会在线上传输原始 Android 文件系统路径或 `content://` URI。示例包括：

- `dm://roots/`
- `dm://app-sandbox/`
- `dm://media-images/`
- `dm://media-videos/`
- `dm://saf-<stable-id>/`

新增或转换路径前阅读[路径模型](path-model.md)。

### 里程碑

- **M0：** 已收口的规格基线。
- **M1：** 当前产品、transport 和协议验证里程碑。
- **v1.0：** 未来可分发版本；完成剩余 M1 证据并处理暂缓的签名/公证路径后才能作此
  声明。

AOA 仍是实验路径，不阻塞当前 ADB M1 的完成。

## 开发流程

1. 写变更契约：目标、文件所有权、不变量、验收命令、非目标和停止条件。
2. 阅读对应的当前事实文档和测试。
3. 完成最小、可审查的变更；不触碰生成代码和无关文件。
4. 先运行窄测试，再运行完整受影响门禁。
5. 在同一变更中更新当前文档。
6. 检查完整 diff，报告每个修改文件和跳过的真机/发布工作。
7. 遵循 [GitHub 治理](github-governance.md)和 [CONTRIBUTING.md](../CONTRIBUTING.md)
   中的风险与集成规则。

普通问题和 bug 可提交 GitHub issue。安全问题遵循 [SECURITY.md](../SECURITY.md)，不要在
公开 issue 中附带凭据、原始设备 serial、私有路径或用户文件。
