# 开发者入门指南

欢迎来到 DroidMatch！本指南将帮助你快速上手代码库。

## DroidMatch 是什么？

DroidMatch 是一款面向 macOS 的现代 Android 设备管理客户端，设计为 HandShaker 的替代品。它原生支持 Apple Silicon，专注于稳定性和速度，并以诊断和本地优先原则构建。

**当前状态：** M1 harness 阶段（连接和文件传输验证）

## 快速开始（5分钟）

### 前置要求
- macOS 13+ (Mac 开发)
- Xcode 命令行工具
- Android SDK 和 ADB
- Java 17+ (Android 开发)

### 克隆和验证
```bash
git clone <repository-url>
cd DroidMatch

# 验证 M0 规格和 protobuf 编译
bash tools/check-m0.sh
bash tools/check-proto.sh

# 构建 Mac harness
swift build --package-path mac

# 构建 Android APK
cd android && ./gradlew :app:assembleDebug
```

### 运行第一个测试
```bash
# 通过 USB 连接 Android 设备
adb devices -l

# 快速冒烟测试（如果设备已连接）
tools/quick-test-scenarios.sh basic-smoke --serial <your-serial>
```

## 必读文档（30分钟）

按顺序阅读这些文档：

1. **[README.md](../README.md)** - 项目概览和当前状态
2. **[docs/m0-closeout.md](m0-closeout.md)** - 规格决策
3. **[docs/m1-status.md](m1-status.md)** - 当前实现状态
4. **[docs/protocol.md](protocol.md)** - 线协议概览
5. 选择你的平台（代码概览目前为英文）：
   - Mac: **[docs/mac-code-overview.md](mac-code-overview.md)**
   - Android: **[docs/android-code-overview.md](android-code-overview.md)**

## 文档地图

### 入门
- **[README.md](../README.md)** - 从这里开始
- **[CONTRIBUTING.md](../CONTRIBUTING.md)** - 如何贡献
- **[SECURITY.md](../SECURITY.md)** - 安全政策
- **本文件** - 入门指南

### 架构和设计
- **[docs/architecture.md](architecture.md)** - 系统架构
- **[docs/product-scope.md](product-scope.md)** - 范围内/外功能
- **[docs/feature-matrix.md](feature-matrix.md)** - 功能对比
- **[docs/handshaker-relationship.md](handshaker-relationship.md)** - 与 HandShaker 的关系
- **[docs/security-model.md](security-model.md)** - 安全边界

### 协议和实现
- **[docs/protocol.md](protocol.md)** - 线协议模式
- **[docs/protocol-runtime.md](protocol-runtime.md)** - 运行时限制和调度
- **[docs/path-model.md](path-model.md)** - 逻辑路径抽象
- **[docs/android-permissions.md](android-permissions.md)** - Android 权限模型

### 代码概览
- **[docs/mac-code-overview.md](mac-code-overview.md)** - Mac 代码库指南（英文）
- **[docs/android-code-overview.md](android-code-overview.md)** - Android 代码库指南（英文）
- **[mac/README.md](../mac/README.md)** - Mac 构建说明
- **[android/README.md](../android/README.md)** - Android 构建说明

### 测试和状态
- **[docs/m1-status.md](m1-status.md)** - 当前 M1 状态总结
- **[docs/m1-testing-guide.md](m1-testing-guide.md)** - 分步测试说明
- **[docs/m1-device-matrix.md](m1-device-matrix.md)** - 所需设备和标准
- **[fixtures/m1-runs/README.md](../fixtures/m1-runs/README.md)** - 测试结果指南

## 常见任务

### 构建

**Mac:**
```bash
swift build --package-path mac
bash tools/run-swift-tests.sh
```

**Android:**
```bash
cd android
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
./gradlew :app:lintDebug
```

### 测试

**快速测试场景：**
```bash
# 查看所有场景
tools/quick-test-scenarios.sh help

# 基础冒烟测试
tools/quick-test-scenarios.sh basic-smoke --serial <serial>

# 下载吞吐量测试
tools/quick-test-scenarios.sh download-100mb-throughput --serial <serial>

# 完整 M1 矩阵（约10分钟）
tools/quick-test-scenarios.sh full-matrix --serial <serial>
```

**手动 harness 命令：**
```bash
# 列出设备
swift run --package-path mac droidmatch-harness devices

# 创建 ADB forward
swift run --package-path mac droidmatch-harness forward \
  --serial <serial> --remote-port 39001

# M1 冒烟测试
swift run --package-path mac droidmatch-harness m1-smoke \
  --port <local-port>
```

### 重新生成 Protobuf

**Mac:**
```bash
brew install protobuf
bash tools/generate-swift-proto.sh
```

**Android:**
```bash
cd android
./gradlew :app:generateDebugProto
```

### 本地运行 CI 检查
```bash
bash tools/check-m0.sh
bash tools/check-proto.sh
bash tools/check-m1-skeleton.sh
```

## 核心概念

### DroidMatch 逻辑路径
DroidMatch 使用逻辑路径而非原始 Android 文件系统路径：
- `dm://roots/` - 虚拟根目录列表
- `dm://media-images/` - MediaStore 图片
- `dm://media-videos/` - MediaStore 视频
- `dm://app-sandbox/` - 应用私有文件
- `dm://saf-<stable-id>/` - 用户选择的 SAF 目录

详见 [docs/path-model.md](path-model.md)。

### 协议栈
1. **传输层：** 通过 ADB forward 或 AOA 的 TCP
2. **分帧：** 长度前缀（uint32_be + payload，最大 4 MiB）
3. **RPC：** 带 request/response/error 的 Protobuf `RpcEnvelope`
4. **传输：** 带 CRC32 验证的接收端控制块

详见 [docs/protocol.md](protocol.md)。

### M1 范围
M1 在产品 UI 工作开始前验证 harness。包括：
- ✅ 握手和心跳
- ✅ 设备信息和诊断
- ✅ 目录列表（media、SAF、app-sandbox）
- ✅ 单流下载/上传
- ✅ M1 双下载多路复用探针（两条活跃流，并验证控制平面 heartbeat）
- ✅ 带指纹验证的传输恢复
- ✅ 传输取消和暂停
- ✅ 可配置的进程内传输丢失恢复队列（历史默认仍为单次重试）
- ✅ 产品异步混合多路复用本地覆盖（唯一 reader、原子下载文件接收、预检上传窗口、协议取消和 heartbeat 路由）
- ✅ 产品下载/上传 sidecar 恢复 coordinator 和可观察进程内 scheduler
- ✅ MainActor 原生传输 presentation 绑定、隐私受限的 row item 与 scheduler 权威动作
- ✅ 双下载/混合方向 probe 都已可由真机脚本调用
- ⚠️ 尚缺归档双流/混合流真机证据
- ✅ 可选 Core 持久队列重建、executor 启动前写入门槛与 sidecar 守门恢复
- ⚠️ 未来 app 生命周期、存储 URL、sandbox 文件访问和 `interrupted` 恢复交互装配
- ⚠️ 视觉 macOS app target 与传输队列界面

详见 [docs/m1-status.md](m1-status.md) 获取详细清单。

## 项目结构

```
DroidMatch/
├── android/          # Android 应用（前台服务、RPC 调度器、提供者）
├── mac/              # Mac harness（ADB 客户端、分帧 TCP、M1 冒烟客户端）
├── proto/            # Protobuf 模式（v1/rpc.proto、transfer.proto 等）
├── docs/             # 文档（架构、协议、测试）
├── tools/            # 脚本（check-m0.sh、run-m1-device-smoke.sh 等）
├── fixtures/         # 测试数据和结果日志
└── .github/          # CI 工作流
```

## 开发工作流

1. **选择任务** 从 [docs/m1-status.md](m1-status.md) "下一步"
2. **阅读相关文档**（协议、代码概览、架构）
3. **进行更改**（Mac 和/或 Android）
4. **本地测试：**
   - 运行单元测试
   - 手动运行 harness 命令
   - 使用 `quick-test-scenarios.sh` 进行集成测试
5. **更新文档：**
   - 如果项目状态改变，更新 README
   - 如果功能完成，更新 `docs/m1-status.md`
   - 如果相关，添加测试日志到 `fixtures/m1-runs/`
6. **运行 CI 检查：** `bash tools/check-m1-skeleton.sh`
7. **提交并推送**（参见 [CONTRIBUTING.md](../CONTRIBUTING.md)）

## 常见问题

**问：如果我想添加新的 RPC 请求，从哪里开始？**
答：参见 [docs/mac-code-overview.md](mac-code-overview.md) 和 [docs/android-code-overview.md](android-code-overview.md) 中的"添加新 RPC 请求"部分（目前为英文）。

**问：如何在真机上运行测试？**
答：参见 [docs/m1-testing-guide.md](m1-testing-guide.md) 获取分步说明。

**问：M0、M1 和 v1.0 有什么区别？**
答：
- **M0：** 规格阶段（已完成）
- **M1：** Harness 验证阶段（当前）
- **v1.0：** 首次产品发布（未来，需要产品 UI）

**问：为什么还没有产品 UI？**
答：M1 在 UI 工作开始前验证协议和传输可靠性。这确保基础牢固。

**问：我可以帮助测试吗？**
答：可以！我们需要在 API 26-29（Slot A）和 API 33-35（Slot C）设备上进行测试。参见 [docs/m1-device-matrix.md](m1-device-matrix.md)。

**问：AOA 路径的状态如何？**
答：AOA（Android Open Accessory）是实验性的，在 ADB 路径在 3 个设备上完成 M1 验证之前被阻止。

## 沟通

- **Issues：** 将 bug、功能请求或问题作为 GitHub issues 提交
- **Pull Requests：** 参见 [CONTRIBUTING.md](../CONTRIBUTING.md) 获取指南
- **安全：** 参见 [SECURITY.md](../SECURITY.md) 报告漏洞

## 下一步

完成入门后：

1. **选择你的平台：** Mac 或 Android
2. **阅读代码概览：** [mac-code-overview.md](mac-code-overview.md) 或 [android-code-overview.md](android-code-overview.md)（目前为英文）
3. **浏览代码：** 从概览中提到的文件开始
4. **运行测试：** 连接设备并尝试 `quick-test-scenarios.sh`
5. **选择任务：** 查看 [docs/m1-status.md](m1-status.md) 了解待处理工作
6. **提出问题：** 如果有不清楚的地方，提交 issue

欢迎加入团队！🚀
