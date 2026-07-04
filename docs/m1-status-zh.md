# M1 状态总结

最后更新：2026-07-05

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
  - 单流下载（接收端控制，带 CRC32 验证）
  - 单流上传（接收端控制，到 app-sandbox/MediaStore/SAF）
  - 下载恢复（带源指纹验证）
  - 上传恢复（app-sandbox 和 SAF）
  - 传输取消和暂停
  - 基于 sidecar 的传输丢失重试（一次尝试）
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
- 传输丢失重试：仅一次自动重连尝试
  - 尚未实现带指数退避的完整恢复队列
  - 当前重试逻辑：检测丢失 → 重连 → 握手 → 使用 sidecar 恢复
- 并发：仅单流传输
  - 协议支持 stream_id 进行多路复用
  - 尚未实现 2 个并发传输的调度器

**测试覆盖：**
- Slot D 设备（NIO N2301，API 34）：广泛覆盖
- Slot A（API 26-29）：尚无测试
- Slot C（API 33-35）：尚无测试（除非 NIO 也充当此角色）
- 握手稳定性：未记录 20/20 次尝试运行
- 吞吐量：存在 100MB 传输但某些日志缺少吞吐量指标

### ❌ 尚未实现

**核心功能（按 M1 范围）：**
- 多流传输调度（协议就绪，harness 未实现）
- 完整自动恢复队列（超出单次重试）
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
| ADB 握手 ≥19/20 | ✅ Slot D 通过 | NIO N2301 Slot D 已记录 20/20 次尝试 |
| USB 插入 ≤5s | ⚠️ 需要测量 | 设备冒烟显示"已授权" |
| 首次列表 ≤1s（预热） | ⚠️ 需要断言/调优 | app-sandbox 记录 937-943ms；最新 media-images 运行是 1042ms；已新增 `--max-list-ms` gate |
| 100MB 下载 ≥20 MiB/s | ⚠️ 需要断言 | 存在 100MB 测试，但未全部记录吞吐量 |
| 下载恢复 | ✅ 已实现 | 带指纹验证的部分 + 恢复 |
| App-sandbox 上传恢复 | ✅ 已实现 | 带截断/重放容忍的部分 + 恢复 |
| Sidecar 传输重试 | ✅ 已实现 | 带故障注入的一次尝试重试 |
| Fresh MediaStore 上传 | ✅ 已实现 | Pictures/Movies 集合 |
| Fresh SAF 上传 | ✅ 已实现 | 用户选择的可写根 |
| SAF 上传恢复 | ✅ 已实现 | Transfer-id 隐藏部分文档 |
| 权限拒绝映射 | ✅ 已实现 | Media 权限撤销测试 |
| 诊断归因 | ✅ 已实现 | 服务/权限/传输状态 |
| 三设备覆盖 | ❌ 缺失 | 仅测试了 Slot D（NIO N2301） |
| AOA 可行性（2 设备） | ❌ 阻止 | 等待 ADB 路径完成 |

## 即时下一步

### 高优先级（M1 阻塞项）

1. **运行带断言的吞吐量测试**：
   ```bash
   # 下载
   tools/run-m1-device-smoke.sh --serial <serial> \
     --prepare-app-sandbox-file dm-100mb-zero.bin \
     --resume-check \
     --chunk-size-bytes 1048576 \
     --min-download-mib-per-second 20

   # 上传
   tools/run-m1-device-smoke.sh --serial <serial> \
     --upload-source /tmp/100mb-upload.bin \
     --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
     --chunk-size-bytes 1048576 \
     --min-upload-mib-per-second 20 \
     --cleanup-upload-destination
   ```

2. **用显式 gate 重复预热列表延迟测试**：
   ```bash
   tools/run-m1-device-smoke.sh --serial <serial> \
     --list-path dm://media-images/ \
     --max-list-ms 1000
   ```

3. **获取 Slot A 和 Slot C 设备** 并运行基本矩阵

### 中优先级（M1 增强）

4. **实现多流调度：**
   - 扩展 harness 以打开 2 个并发传输
   - 验证 stream_id 多路复用
   - 展示双传输期间控制平面保持响应

5. **实现完整恢复队列：**
   - 带指数退避的多次重试尝试
   - 跨应用重启的持久队列（M1 后）
   - 诊断中的用户可见重试状态

6. **扩展 SAF 上传测试：**
   - 在多个 OEM 上测试可写 SAF 目录
   - 验证非最终关闭时的部分文档清理
   - 记录厂商的 SAF 提供者特性

### 低优先级（M1 后）

7. **USB 时序测量：**
   - 线缆插入到设备可见的延迟
   - 授权流程时序
   - 拔插后重连

8. **大目录压力测试：**
   - 1000+ 条目的 MediaStore 列表
   - 分页性能
   - 提供者内存使用

9. **AOA 路径探索：**
   - 在 ADB 在 3 个设备上通过 M1 后
   - 需要至少 2 个支持 AOA 的设备
   - 吞吐量目标：≥30 MB/s

## 已知限制

- **单流传输：** 当前 harness 一次打开一个传输
- **单次重试：** 传输丢失仅触发一次重连尝试
- **SAF 上传无自动清理：** 需要手动删除，直到存在 delete/mutation 协议
- **MediaStore fresh-only：** 不支持上传恢复（返回 unsupportedCapability）
- **仅 ADB loopback：** Android endpoint 拒绝非 127.0.0.1 客户端
- **需要 debug harness Activity：** 某些 OEM 设备在没有前台 Activity 的情况下冻结服务 accept() 线程

## 测试结果摘要

截至 2026-07-05，`fixtures/m1-runs/` 包含：
- 12 个测试结果日志
- 全部来自 NIO N2301（Slot D，API 34）
- 覆盖：app-sandbox 上传（fresh/resume/100MB）、MediaStore 上传、cancel、pause、Slot D 握手稳定性（20/20）
- 缺失：吞吐量断言、预热列表 ≤1s 断言、Slot A/C 设备

## 参考文档

- [M1 测试指南](m1-testing-guide-zh.md)：分步测试说明
- [M1 设备矩阵](m1-device-matrix.md)：所需设备和通过标准
- [M0 收口](m0-closeout.md)：规格决策
- [协议运行时](protocol-runtime.md)：并发限制和反压
- [协议](protocol.md)：消息模式和语义
- [路径模型](path-model.md)：逻辑路径抽象
