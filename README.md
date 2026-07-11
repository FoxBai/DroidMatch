# DroidMatch

DroidMatch 是一款 macOS 原生的 Android 设备管理器。它以 USB/ADB 为当前稳定通道，由 Mac 产品 App 和 Android 安全 companion 共同完成配对、权限管理、文件浏览与可靠传输。

项目借鉴 HandShaker 中有价值的工作流，但不延续其品牌、视觉资产、二进制或代码实现。详见 [DroidMatch 与 HandShaker 的关系](docs/handshaker-relationship.md)。

> 当前处于 M1 收口期。Mac 已有可构建的 SwiftUI 产品 App；Android 已有配对、连接、信任和 SAF 授权入口，但不是独立文件管理器。Developer ID 签名、公证、DMG，以及产品路径的真机认证/传输证据仍未完成。

## 项目方向

- **本地优先**：USB 优先，默认不依赖云服务。
- **双端原生重写**：Mac 与 Android 分别承担清晰的平台职责。
- **稳定路径优先**：ADB 是当前主路径；AOA 在完成数据验证前保持实验状态。
- **传输可信**：关注断点续传、完整性校验、原子落盘、取消与可诊断错误。
- **边界清晰**：产品 UI、协议、传输、存储提供方和平台权限彼此解耦。

## 当前能力

核心产品路径已经具备：

- 在认证后的 Mac 文件浏览器中，通过 `file_write` 能力在 App Sandbox 和可写 SAF 目录新建直接子文件夹；名称与平台路径均受 provider 边界校验。
- 可写的普通文件和目录支持同目录重命名；跨目录移动不会伪装成 rename，虚拟 root 与只读条目不显示该操作。
- 可写文件和目录支持经破坏性二次确认后永久删除；目录请求始终携带 recursive 确认，provider root 永不可删除。
- 文件浏览器支持 250ms debounce 的当前目录 provider-side 名称搜索，以及名称、修改时间、大小的升降序切换；列表与媒体网格均显示大小/修改日期并提供原生右键操作。过滤和排序发生在分页前，查询变化会使旧 opaque page token 失效。
- 选择模式支持对当前已加载的可写文件/目录进行稳定 path 多选和批量删除；顺序执行若部分失败会强制刷新远端目录对账。
- Finder 可向可写 Android 目录一次拖入最多 100 个名称唯一的普通文件；每个文件复用 sandbox bookmark 和持久上传队列，不接受目录或非 file URL。
- 选择模式可把多个可读远端文件下载到用户选择的本地目录；入队前拒绝远端同名和已存在目标，避免任何静默覆盖。

- Mac 端 ADB 发现与转发、framed TCP/RPC、全异步会话及命令行 harness。
- SwiftUI Mac 产品 target、本地 `.app` 组装脚本，以及中英文设备发现、连接、SAS 审批、分页文件浏览和隐私受限诊断界面；ADB 进程与 serial 均停留在 Core 边界内。
- Android 前台连接服务、paired-required loopback ADB endpoint、配对/权限 onboarding 与协议 dispatcher；debug harness 单独保留 nonce-only 证据模式。
- 目录浏览，以及 App Sandbox、MediaStore、SAF 的下载和上传能力；MediaStore 图片支持带懒加载封面的 opaque 相册视图，图片/视频支持列表/自适应网格、有界缩略图和点击预览。
- Mac 产品层分页目录 API 与 MainActor 浏览模型，支持 refresh/load-more、opaque token、防旧响应覆盖和跨页去重。
- CRC32 校验、原子下载、断点续传、传输取消、检查点暂停、重试、双流调度和吞吐量测量。
- 可选的版本化传输队列 manifest：原子写入、稳定 FIFO/任务 ID，并以 sidecar 守门跨 scheduler 重建恢复。
- 本地验证过的双下载与下载/上传混合流；真机脚本可生成脱敏证据。
- `DroidMatchPresentation` 队列展示模型，以及由原生保存/文件选择面板提交、支持进度与暂停/继续/取消/移除的真实下载和上传队列界面。
- 首次配对与重连认证的协议、密码学实现和本地测试；Android 产品入口与 Mac 生命周期会话均已接通 paired-required 模式，真机配对/重连证据仍待归档。

仍未完成：

- **M1 阻塞项**：SHARP 704SH（API 26）100 MiB 上传/下载尚未达到 20 MiB/s 门槛。
- USB 拔插、可写 SAF、双下载和混合流还需补齐对应真机证据。
- Developer ID 签名、公证、DMG 和发布流程尚未验证；AOA 仍是 M1 后探索项。

Mac 产品会话、文件浏览、结构化诊断、按认证设备隔离的持久双向传输队列和 bookmark 恢复租约已经装配；Android 产品入口负责连接安全与存储授权，不是独立的本地文件浏览器。App Sandbox bundle 已验证内置 adb 的两台设备发现，但产品会话尚无完整归档的真机配对/重连/下载/上传证据，当前 App 不能被描述成可分发版本。

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

构建并启动当前 Mac 产品壳：

```bash
tools/build-mac-app.sh
open mac/.build/app/DroidMatch.app
```

脚本生成本地 ad-hoc 签名的 `.app`；Developer ID 签名、公证和 DMG 仍需完整 Xcode 与发布凭据。

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
| 维护接管、事故处理与发布判断 | [维护者运行手册](docs/maintainer-runbook.md) |
| 系统边界与模块职责 | [架构](docs/architecture.md) |
| 结构性技术债与拆分顺序 | [结构性债务基线](docs/technical-debt.md) |
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
