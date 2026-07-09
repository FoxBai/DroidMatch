# M1 状态总结

最后更新：2026-07-09

## 当前实现状态

### ✅ 已完成功能

**Mac 端：**
- ADB 客户端（发现、转发、设备列表）
- Frame 编解码器（4 MiB 最大，长度前缀）
- 分帧 TCP 客户端/会话（Network.framework）
- 握手冒烟客户端（ClientHello/ServerHello）
- M1 冒烟客户端（完整控制平面测试）
- RPC 控制客户端（请求/响应处理）
- 传输实现：
  - 单流下载（窗口化接收端控制，带 CRC32 验证）
  - 单流上传（窗口化，4 chunk / 2 MiB 在途，到 app-sandbox/MediaStore/SAF）
  - 下载恢复（带源指纹验证）
  - 上传恢复（app-sandbox 和 SAF）
  - 传输取消和暂停
  - 基于 sidecar 的传输丢失重试（默认历史单次重试，可用 `--max-retry-attempts` 开启可配置恢复队列）
  - 原子下载写入器（部分 → 最终提交）
- CLI harness，命令包括：devices、forward、handshake-smoke、m1-smoke、list-dir、download、upload 等
- 吞吐量测量（elapsed_ms、throughput_mib_per_sec）

**Android 端：**
- 前台连接服务
- ADB endpoint（仅 loopback，带超时）
- 分帧 I/O（uint32_be 长度 + payload）
- RPC 调度器（会话管理、请求路由）
- 协议处理器：
  - ClientHello/ServerHello
  - HeartbeatRequest
  - DeviceInfoRequest
  - ListDirRequest（roots、media、SAF、app-sandbox）
  - OpenTransferRequest（下载和上传）
  - TransferChunk/TransferChunkAck
  - CancelTransferRequest
  - PauseTransferRequest
  - DiagnosticsRequest
- 文件提供者：
  - MediaStore（通过 content resolver 访问图片/视频）
  - SAF（tree URI 权限、目录列表）
  - App sandbox（私有 files/droidmatch-sandbox）
- 提供者功能：
  - 下载：可定位 FD 或带偏移跳过的流
  - 上传：隐藏部分文件，最终块时原子提交
  - 恢复：源指纹验证（下载）、部分偏移验证（上传）
  - ACK 丢失容忍（app-sandbox 上传截断/重放）
- 权限状态提供者
- 诊断报告器（带并发测试覆盖）
- Debug harness Activity（在测试期间保持 endpoint 活跃）
- 启动器入口（DiagnosticsActivity 用于授权）

**工具：**
- `tools/run-m1-device-smoke.sh`：综合设备测试脚本
- `tools/m1-fault-proxy.py`：用于故障注入的本地帧代理
- `tools/check-m1-skeleton.sh`：CI 验证
- `tools/check-m1-run-logs.sh`：日志脱敏验证
- 自动结果记录到 `fixtures/m1-runs/`

**文档：**
- M0 收口（规格已最终确定）
- 协议文档（模式、运行时、路径）
- 设备矩阵要求
- 测试指南（退出标准的分步说明）
- 架构、安全模型、功能矩阵

### ⚠️ 部分实现

**传输功能：**
- 传输丢失重试：现已通过 `RecoveryPolicy` 实现可配置的多尝试恢复队列
  （指数退避、尝试上限、sidecar 守门）。
  - 默认 `--retry-on-transport-loss` 仍复刻历史的单次重试，向后兼容既有真机脚本。
  - `--max-retry-attempts N` 开启最多 N 次额外重连尝试。
  - `--retry-backoff-ms M` 覆盖基准退避（默认 500ms）。
  - 单元测试 + 端到端测试覆盖退避时序、尝试耗尽、本地故障注入服务器的多次断线恢复。
  - 跨进程重启的持久化恢复队列仍属 M1 之后。
- 并发：仅单流传输
  - 协议支持 stream_id 进行多路复用
  - 尚未实现 2 个并发传输的调度器

**测试覆盖：**
- Slot D 设备（NIO N2301，API 34）：广泛覆盖
- Slot A（SHARP 704SH，API 26）：已归档满足槽位要求的 handshake/list 证据；100MiB 下载/上传功能完成，但未通过 20 MiB/s 吞吐 gate
- Slot C（MEIZU M20，API 34）：已有 handshake/list、app-sandbox 100MiB 下载/上传恢复吞吐、权限撤销、预期错误、MediaStore fresh-only 上传，以及 sidecar/ACK 丢失恢复覆盖
- 未归类：Pixel 9 Pro Fold（API 37）已有 20/20 双设备 ADB 路由 smoke，但它不满足 Slot A 的 API 26-29 要求
- 握手稳定性：Slot A、Slot C 和 Slot D 都已有 20/20 运行
- 吞吐量：Slot D 和 Slot C 下载/上传已有通过的 100MiB 探针；Slot A 低于 20 MiB/s gate

### ❌ 尚未实现

**核心功能（按 M1 范围）：**
- 多流传输调度（协议就绪，harness 未实现）
- 跨重启的持久化恢复队列（M1 之后；进程内多尝试恢复队列已实现）
- AOA 传输路径（在 ADB 路径完成 M1 前被阻止）

**产品 UI（M1 范围外）：**
- macOS 原生 UI（M1 仅 harness）
- 文件浏览器
- 传输队列 UI
- 设置/偏好
- 通知集成

**可选功能（v1.0 后）：**
- 屏幕镜像
- 通知镜像
- 剪贴板同步
- 文件夹订阅
- Wi-Fi 传输

## M1 退出标准进度

| 标准 | 状态 | 备注 |
|---|---|---|
| ADB 握手 ≥19/20 | ✅ Slot A/C/D 通过 | SHARP 704SH Slot A、MEIZU M20 Slot C 和 NIO N2301 Slot D 都已记录 20/20 次尝试；Pixel 9 Pro Fold API 37 也记录了未归类 20/20 smoke |
| USB 插入 ≤5s | ⚠️ 需要测量 | 设备冒烟显示"已授权" |
| 首次列表 ≤1s（预热） | ✅ Slot A/C/D 通过 | SHARP 704SH Slot A 测得 `elapsed_ms=165`；NIO N2301 Slot D 测得 `elapsed_ms=98`；MEIZU M20 Slot C 测得 `elapsed_ms=84`；命令外层 wall time 单独记录 |
| 100MB 下载 ≥20 MiB/s | ❌ Slot A 低于 gate | Slot C/D 通过：NIO N2301 测得 48.95 MiB/s；MEIZU M20 测得 35.52 MiB/s。SHARP 704SH Slot A 完成恢复下载，但仅测得 16.64 MiB/s，ADB baseline 为 7.19 MiB/s |
| 100MB 上传 ≥20 MiB/s | ❌ Slot A 低于 gate | Slot C/D 通过：NIO N2301 测得 33.51 MiB/s；MEIZU M20 测得 20.22 MiB/s。SHARP 704SH Slot A 完成恢复上传，但仅测得 15.20 MiB/s |
| 下载恢复 | ✅ 已实现 | 带指纹验证的部分 + 恢复；Android 单测覆盖缺失、变化和不可用 source fingerprint |
| App-sandbox 上传恢复 | ✅ 已实现 | 带截断/重放容忍的部分 + 恢复 |
| Sidecar 传输重试 | ✅ Slot C/D 通过 | 故障注入以 `recovered=true` 通过；Slot C 和 Slot D 日志在使用非默认策略时记录了重试策略 |
| Fresh MediaStore 上传 | ✅ Slot C/D 通过 | Pictures/Movies 集合；MEIZU M20 已记录 fresh 上传和非零 offset 恢复拒绝 |
| Fresh SAF 上传 | ✅ 已实现 | 用户选择的可写根 |
| SAF 上传恢复 | ✅ 已实现 | Transfer-id 隐藏部分文档 |
| 权限拒绝映射 | ✅ Slot C/D 通过 | Media 列表撤销返回 `permissionRequired`；Media 下载中撤销在 Slot D 记录为预期 transport loss，在 Slot C 记录为撤销后仍完成；随后恢复授权 |
| 诊断归因 | ✅ 已实现 | 服务/权限/传输状态 |
| 三设备覆盖 | ❌ 受 Slot A 吞吐阻塞 | 所需 Slot A/C/D 设备现在都有记录，但 Slot A 下载/上传吞吐低于 M1 gate |
| AOA 可行性（2 设备） | ❌ 阻止 | 等待 ADB 路径完成 |

## 即时下一步

### 高优先级（M1 阻塞项）

1. **调查 SHARP 704SH（API 26）上的 Slot A 吞吐：** 100MiB 下载完成但只有 16.64 MiB/s，上传完成但只有 15.20 MiB/s，均低于 20 MiB/s gate；原始 ADB baseline 仅 7.19 MiB/s。建议设备充满电后更换线缆/端口重跑，并尽量找第二台 API 26-29 设备交叉验证，再决定是否调整协议假设。

2. **补齐剩余异常/人工场景证据**：上传/下载期间 USB 拔插，以及真机恢复前 source 删除/修改。

### 中优先级（M1 增强）

3. **实现多流调度：**
   - 扩展 harness 以打开 2 个并发传输
   - 验证 stream_id 多路复用
   - 展示双传输期间控制平面保持响应

4. **持久化恢复队列（M1 后）：**
   - 通过磁盘队列状态在 harness/应用重启后存活
   - 诊断中的用户可见重试状态

5. **扩展 SAF 上传测试：**
   - 在多个 OEM 上测试可写 SAF 目录
   - 验证非最终关闭时的部分文档清理
   - 记录厂商的 SAF 提供者特性

### 低优先级（M1 后）

6. **USB 时序测量：**
   - 线缆插入到设备可见的延迟
   - 授权流程时序
   - 拔插后重连

7. **大目录压力测试：**
   - 1000+ 条目的 MediaStore 列表
   - 分页性能
   - 提供者内存使用

8. **AOA 路径探索：**
   - 在 ADB 在 3 个设备上通过 M1 后
   - 需要至少 2 个支持 AOA 的设备
   - 吞吐量目标：≥30 MB/s

## 已知限制

- **单流传输：** 当前 harness 一次打开一个传输
- **重试默认单次：** `--retry-on-transport-loss` 默认仍只重试一次以保持向后兼容；需显式传 `--max-retry-attempts N` 才启用多尝试恢复队列
- **SAF 上传无自动清理：** 需要手动删除，直到存在 delete/mutation 协议
- **MediaStore fresh-only：** 不支持上传恢复（返回 unsupportedCapability）
- **仅 ADB loopback：** Android endpoint 拒绝非 127.0.0.1 客户端
- **需要 debug harness Activity：** 某些 OEM 设备在没有前台 Activity 的情况下冻结服务 accept() 线程

## 测试结果摘要

截至 2026-07-09，`fixtures/m1-runs/` 包含：
- 35 个测试结果日志
- SHARP 704SH（Slot A，API 26）的 handshake/list 和未通过 100MiB 吞吐证据、NIO N2301（Slot D，API 34）的较完整矩阵覆盖、MEIZU M20（Slot C，API 34）的 handshake/list、app-sandbox 吞吐/恢复、权限、预期错误、MediaStore 和恢复证据，以及 Pixel 9 Pro Fold（API 37）的未归类双设备 ADB 路由 smoke
- 覆盖：app-sandbox 上传（fresh/resume/100MB）、app-sandbox 下载恢复/100MB、MediaStore 上传、Media 列表和下载期间权限撤销、预期错误边界、cancel、pause、Slot D 握手稳定性（20/20）、Slot C 握手稳定性（20/20）、Slot D/Slot C 吞吐断言、ADB baseline 下载诊断、可配置恢复策略故障 smoke，以及 app-sandbox ACK 丢失重放
- 通过：Slot D 窗口化下载用 1MiB chunk 测得 48.95 MiB/s，同文件 ADB baseline 为 75.70 MiB/s
- 通过：Slot D 窗口化上传用 1MiB chunk 测得 33.51 MiB/s，通过 20 MiB/s gate
- 通过：Slot D 预热 media-images 列表测得 harness `elapsed_ms=98`，通过 1000 ms gate
- 通过：Slot D Media 权限撤销后 `dm://media-images/` 返回 `permissionRequired`，随后恢复原授权
- 通过：Slot D 在 `dm://media-images/media/1000001148` 下载期间撤销 Media 权限后观测到 `transport_lost_after_revoke`，随后恢复原授权
- 通过：MEIZU M20 Slot C 在 20/20 次 `m1-smoke` 后，预热 media-images 列表测得 harness `elapsed_ms=84`，通过 1000 ms gate
- 通过：MEIZU M20 Slot C app-sandbox 100MiB 下载恢复测得 35.52 MiB/s，ADB baseline 为 36.90 MiB/s
- 通过：MEIZU M20 Slot C app-sandbox 100MiB 上传恢复在 Mac harness send-limit 修复后测得 20.22 MiB/s
- 通过：MEIZU M20 Slot C Media 权限撤销后 `dm://media-images/` 返回 `permissionRequired`，随后恢复原授权
- 通过：MEIZU M20 Slot C 预期错误边界：缺失 SAF root 和缺失 app-sandbox 下载源均返回 `notFound`
- 通过：MEIZU M20 Slot C MediaStore fresh 上传成功，且非零 offset 上传恢复返回 `unsupportedCapability`
- 通过：MEIZU M20 Slot C app-sandbox 上传 ACK 丢失重放以 `recovered=true` 恢复
- 通过：MEIZU M20 Slot C app-sandbox 100MiB 下载故障重试以 `recovered=true` 恢复
- 通过：MEIZU M20 Slot C 在 `dm://media-images/media/1000000054` 下载期间撤销 Media 权限后仍完成下载，随后恢复原授权
- 通过：SHARP 704SH Slot A 握手稳定性 20/20 通过，预热 `dm://media-images/` 列表测得 `elapsed_ms=165`
- 未通过：SHARP 704SH Slot A app-sandbox 100MiB 下载恢复完成，但吞吐为 16.64 MiB/s，低于 20 MiB/s gate；原始 ADB baseline 为 7.19 MiB/s
- 未通过：SHARP 704SH Slot A app-sandbox 100MiB 上传恢复完成，但吞吐为 15.20 MiB/s，低于 20 MiB/s gate
- 通过：Pixel 9 Pro Fold API 37 未归类 smoke 在两台 ADB 设备同时连接时通过显式 serial 路由完成 20/20 次尝试
- 单测覆盖异常路径：stale 下载恢复 source fingerprint、invalid page token、oversized envelope、bad transfer-chunk CRC32
- 缺失：Slot A 吞吐修复/通过证据；Slot C 可写 SAF、USB 异常和真机 source mutation 覆盖

## 参考文档

- [M1 测试指南](m1-testing-guide-zh.md)：分步测试说明
- [M1 设备矩阵](m1-device-matrix.md)：所需设备和通过标准
- [M0 收口](m0-closeout.md)：规格决策
- [协议运行时](protocol-runtime.md)：并发限制和反压
- [协议](protocol.md)：消息模式和语义
- [路径模型](path-model.md)：逻辑路径抽象
