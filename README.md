# DroidMatch

DroidMatch 是一款面向 macOS 的现代 Android 设备管理客户端，目标是提供 Apple Silicon 原生、稳定、快速且可诊断的设备连接与文件传输体验。

项目借鉴 HandShaker 中有价值的工作流，但不延续其品牌、视觉资产、二进制或代码实现。详见 [DroidMatch 与 HandShaker 的关系](docs/handshaker-relationship.md)。

> **当前阶段：M1 传输与协议验证。** 仓库已经具备可运行的 Mac/Android harness、协议实现和真机测试工具，但还没有可交付的 macOS 图形应用。Android 启动器入口目前用于授权和诊断，不是完整的设备管理界面。

## 项目方向

- **本地优先**：USB 优先，默认不依赖云服务。
- **双端原生重写**：Mac 与 Android 分别承担清晰的平台职责。
- **稳定路径优先**：ADB 是当前主路径；AOA 在完成数据验证前保持实验状态。
- **传输可信**：关注断点续传、完整性校验、原子落盘、取消与可诊断错误。
- **边界清晰**：产品 UI、协议、传输、存储提供方和平台权限彼此解耦。

## 当前进度

已经具备：

- Mac 端 ADB 发现与转发、framed TCP/RPC、异步会话及命令行 harness。
- Android 前台连接服务、loopback ADB endpoint、协议 dispatcher 与权限诊断入口。
- 目录浏览，以及 app sandbox、MediaStore、SAF 的下载和上传能力。
- CRC32 校验、原子下载、断点续传、传输取消、检查点暂停、重试、双流调度和吞吐量测量。
- 可选的版本化传输队列 manifest：原子写入、稳定 FIFO/任务 ID，并以 sidecar 守门跨 scheduler 重建恢复。
- 本地验证过的双下载与下载/上传混合流；真机脚本可生成脱敏证据。
- `DroidMatchPresentation` 队列展示模型；它是 UI 状态边界，不是视觉界面。
- 首次配对与重连认证的协议、密码学实现和本地测试；产品启用与真机证据仍待完成。

阻塞 M1 退出或仍需补齐证据：

- **M1 阻塞项**：SHARP 704SH（API 26）100 MiB 上传/下载尚未达到 20 MiB/s 门槛。
- USB 拔插、可写 SAF、双下载和混合流还需补齐对应真机证据。

macOS 产品界面、持久化队列的实际 app 生命周期装配和 AOA 传输属于后续工作，不在当前 M1 已交付范围内。

最新实现、设备证据和退出门槛以 [M1 状态总览](docs/m1-status.md) 为准；历史 fixture 只作为证据，不代替当前状态文档。

## 快速开始

开发环境需要 macOS、Xcode/Swift、JDK 17、Android SDK、ADB、Gradle 所需网络环境，以及 Protocol Buffers 工具链。先运行环境检查，再运行跨端骨架门禁：

```bash
bash tools/check-env.sh --all
bash tools/check-m1-skeleton.sh
```

只验证 Mac 端 Swift package：

```bash
bash tools/run-swift-tests.sh
```

环境变量、Android SDK 配置和常见故障见 [开发者入门](docs/developer-onboarding.md)。CI 与各 gate 的职责见 [CI/CD 指南](docs/ci-cd.md)。

## 真机验证

先确认设备已授权：

```bash
adb devices -l
```

对明确用于测试、并已有清理计划的设备，可运行一键 M1 smoke：

```bash
tools/run-m1-device-smoke.sh --serial <serial>
```

该脚本会安装 debug APK、启动测试服务、创建 ADB forward；部分参数还会写入或清理测试文件、修改临时权限。不要直接对含重要数据的设备运行。完整参数、数据清理规则和证据归档方式见 [M1 真机测试指南](docs/m1-testing-guide.md)，设备分层与验收门槛见 [M1 设备矩阵](docs/m1-device-matrix.md)。

## 仓库结构

```text
DroidMatch/
├── android/           # Android app、endpoint、协议与存储提供方
├── mac/               # Swift package、核心传输、展示模型与 harness
├── proto/v1/          # 跨端 wire schema 的唯一事实源
├── docs/              # 架构、状态、协议、安全和测试文档
├── tools/             # 环境检查、生成、gate 与真机脚本
├── fixtures/m1-runs/  # 脱敏后的真机运行证据
└── .github/workflows/ # CI 工作流
```

## 文档导航

| 主题 | 从这里开始 |
|---|---|
| 当前能力、缺口与设备证据 | [M1 状态总览](docs/m1-status.md) |
| 新开发者环境与首次验证 | [开发者入门](docs/developer-onboarding.md) |
| 系统边界与模块职责 | [架构](docs/architecture.md) |
| Wire schema 与运行时约束 | [协议](docs/protocol.md) · [协议运行时](docs/protocol-runtime.md) |
| 虚拟路径与权限边界 | [路径模型](docs/path-model.md) · [安全模型](docs/security-model.md) |
| 配对与重连认证 | [配对认证设计](docs/pairing-auth-design.md) |
| Mac 端实现 | [Mac README](mac/README.md) · [Mac 代码导览](docs/mac-code-overview.md) |
| Android 端实现 | [Android README](android/README.md) · [Android 代码导览](docs/android-code-overview.md) |
| 真机测试与验收 | [M1 测试指南](docs/m1-testing-guide.md) · [设备矩阵](docs/m1-device-matrix.md) |
| 已收口的 M0 规格 | [M0 收口记录](docs/m0-closeout.md) |

## 参与开发

修改前请阅读 [贡献指南](CONTRIBUTING.md) 和 [Agent Guide](AGENTS.md)。核心约束包括：

- `proto/v1/*.proto` 是 wire schema 的唯一事实源，不手改生成代码。
- 不把 harness、展示模型或计划中的功能描述成已经完成的产品 UI。
- 协议、传输、权限、设备证据或 gate 变化时，同步更新对应的当前文档。
- 真机结果必须来自真实、脱敏的运行；不得为了通过 gate 手工编造或修改证据。

## 许可

DroidMatch 使用 [Mozilla Public License 2.0](LICENSE) 授权。
