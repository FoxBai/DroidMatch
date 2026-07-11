# M1 状态总结

最后更新：2026-07-12

## 当前实现状态

### ✅ 已完成功能

**Mac 端：**
- ADB 客户端（发现、转发、设备列表）
- Frame 编解码器（4 MiB 最大，长度前缀）
- 分帧 TCP 客户端/会话（Network.framework）
- 握手冒烟客户端（ClientHello/ServerHello）
- M1 冒烟客户端（完整控制平面测试）
- RPC 控制客户端（请求/响应处理）
- 面向产品层的异步 TCP/RPC actor（连接级 I/O 模式、唯一 multiplexed reader、request deadline 与取消安全 teardown）
- SwiftUI `DroidMatch` 产品 target：中英文设备总览、按 canonical path 本地化内置 provider 根、隐藏 opaque path 的可读导航标题、异步 ADB 发现、进程内 opaque 设备 ID、旧快照提示、生成式原生图标，以及已验证的本地 ad-hoc `.app` bundle
- 产品会话生命周期：匿名动态 forward lease、按稳定身份选择 Keychain 记录、可见 SAS 审批、配对重连 proof、认证后的分页文件浏览，以及可导出 schema-v1 allowlist JSON（产品/macOS 版本与快照新鲜度）的隐私受限结构化诊断
- Mac 端共享 envelope 校验（`frame_version`、可选 payload CRC、response/error request 关联）
- 已强制握手 nonce 关联，并完成本地测试覆盖的首次配对/重连安全状态机；Slot C 已归档普通 App 的可见 SAS 配对、Keychain 重连、空闲保活和下载，以及 sandbox App 的配对、浏览、双向传输与强制终止后上传恢复
- 传输实现：
  - 单流下载（窗口化接收端控制，带 CRC32 验证）
  - 单流上传（窗口化，4 chunk / 2 MiB 在途，到 app-sandbox/MediaStore/SAF）
  - 单会话脚本化双下载流 smoke（按 stream ID 路由、公平处理 chunk、双流活跃时验证 heartbeat）
  - 单会话产品异步上传/下载混合 handle，并已在本地验证原子文件接收、四块上传窗口、heartbeat、取消与 refill 路由；同一成功契约现已由 `mixed-transfer-smoke` 暴露
  - 下载恢复（带源指纹验证）
  - 上传恢复（app-sandbox 和 SAF）
  - 传输取消和暂停
  - 会话内活跃 transfer ID 唯一、上传取消，以及以 ACK 为边界的下载暂停 offset
  - 基于 sidecar 的传输丢失重试（默认历史单次重试，可用 `--max-retry-attempts` 开启可配置恢复队列）
  - 原子下载写入器（部分 → 最终提交）
- CLI harness，命令包括：devices、forward、handshake-smoke、m1-smoke、dual-download-smoke、mixed-transfer-smoke、list-dir、download、upload 等
- 吞吐量测量（elapsed_ms、throughput_mib_per_sec）
- 可选的版本化传输队列 manifest：原子写入、稳定 job/FIFO identity、私有文件权限、sidecar 守门的 scheduler 重建，以及禁止自动重放的 `interrupted` 状态
- 不依赖 protobuf 的产品目录 domain 类型、分页/搜索/排序 `AsyncRpcControlClient` listing、内嵌错误/row/token 校验，以及支持原子 refresh、250ms 搜索 debounce、provider-side 名称/修改时间/大小升降序、已加载项目全选/清除与 stale selection 对账、稳定 path 多选/顺序批量删除、多文件下载防覆盖、Finder 多文件拖放上传、部分失败对账、可重试 load-more、旧 generation 拒绝、跨页去重和脱敏失败状态的 MainActor `DirectoryBrowserModel`；UI-only 文件名净化不改变 remote identity，列表/网格显示大小和本地化修改日期并提供能力受限的原生右键操作，MediaStore 图片/视频另有可见项缩略图和 512 px 点击预览，单响应限制 512 KiB、列表缓存限制 64 项
- 独立 `DroidMatchPresentation` library 与 MainActor `TransferQueueModel`：有序全量快照、显式幂等 start/stop/restart、非乐观 pause/resume/cancel/remove 回送、任务退场后的精确移除能力，以及仅含本地 basename 的展示状态
- 已认证的持久双向产品队列：可读文件使用原生保存面板，可写 app-sandbox/SAF/MediaStore 目录使用原生单文件选择器；manifest 按认证设备指纹隔离并私密保存；每次尝试都通过会话 gate 创建新的配对 RPC client；app-sandbox/SAF 可恢复重试，MediaStore 保持 fresh-only；断开时暂停可恢复任务、阻断不安全重放，再释放 forward
- MainActor `DeviceDiscoveryModel`：原子 refresh、取消/generation 防护、脱敏失败状态，并确保 ADB serial 不进入 presentation

**Android 端：**
- 前台连接服务
- ADB endpoint（仅 loopback，带超时）
- 分帧 I/O（uint32_be 长度 + payload）
- RPC 调度器（会话管理、请求路由）
- 协议处理器：
  - ClientHello/ServerHello
  - HeartbeatRequest
  - DeviceInfoRequest
  - ListDirRequest（roots、media、SAF、app-sandbox；provider-side `search_query` 在分页前过滤并绑定 opaque token）
  - OpenTransferRequest（下载和上传）
  - TransferChunk/TransferChunkAck
  - CancelTransferRequest
  - PauseTransferRequest
  - DiagnosticsRequest
- 文件提供者：
  - MediaStore（通过 content resolver 访问图片/视频）
  - MediaStore 图片相册（API 26–34 bucket 聚合、严格 opaque token、懒加载最新图片封面、相册内复用 canonical media path）
  - SAF（tree URI 权限、目录列表）
  - App sandbox（私有 files/droidmatch-sandbox）
- 提供者功能：
  - 下载：可定位 FD 或带偏移跳过的流
  - 上传：隐藏部分文件，最终块时原子提交
  - 恢复：源指纹验证（下载）、部分偏移验证（上传）
  - ACK 丢失容忍（app-sandbox 上传截断/重放）
- 权限状态提供者
- 诊断报告器（带并发测试覆盖）
- Debug harness Activity（供真机脚本使用的独立 nonce-only 证据路径）
- 产品启动器入口（`DroidMatchActivity`）：提供经过单测的下一步就绪摘要，控制 paired-required endpoint、处理配对审批、列出/撤销不含密钥的已配对 Mac 元数据、处理通知权限并管理 SAF 授权；撤销信任会关闭活动 USB 会话，diagnostics harness 命名仅保留在 debug source
- 针对应用私有数据、配对、SAF、传输和诊断状态的显式禁备份/禁设备迁移规则
- 原创 adaptive vector launcher 标识，支持 Android 13+ monochrome 主题图标

**工具：**
- `tools/check-source-size.py`：全部手写生产、单元测试与 instrumentation 测试源码统一执行 800 行上限，已无存量例外
- `tools/run-m1-device-smoke.sh`：综合设备测试脚本，含显式启用的 `--dual-download-check`，以及需要独立 fresh 上传目标的 `--mixed-transfer-check`
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

**配对与认证：**
- 当前 Hello 已强制 nonce 新鲜度/关联校验。
- v1 P-256 首次配对与两阶段 HMAC 重连方案已写入 `docs/pairing-auth-design.md`。
- Swift/Java canonical transcript、SHA-256、角色隔离 HMAC、常量时间校验和 HKDF 已通过同一固定向量。
- 两阶段重连 protobuf、Android challenge/proof 状态机、Mac async 双向 proof 校验、降级检测、未知 ID/坏 proof 统一失败和认证前 capability 拒绝已实现并通过测试。
- 首次配对 start/confirm/finalize protobuf、跨端 P-256/ECDH + 无偏 SAS + confirmation 原语、禁同步 Keychain store 和 Android Keystore AES-GCM wrapping store 已实现，并通过固定向量与注入 backend 测试。
- Android 稳定身份签名、默认关闭的 120 秒可见配对窗口、start/confirm/finalize dispatcher、Mac async client 和临时 Keychain 回滚已实现，并有 JVM 与 loopback 端到端测试。
- 首次配对、单 ID 重连和跨 ID 全局失败压力现已使用进程级指数退避，并覆盖随机 ID 轮换、空闲过期、内存上限和统一失败外形测试。
- 隔离的 AndroidX instrumentation runner 已在用户手动批准测试 APK 安装弹窗后于 Slot C MEIZU M20 通过：稳定 P-256 identity 与 AES wrapping key 均保持不可导出，签名、加密 record 重开及撤销 round trip 成功。这是需要人在场的证据，不代表可无人值守安装；runner 只移除测试包，并保留产品安装/数据边界。
- Mac 与 Android 均已提供不暴露密钥的信任管理。Mac 撤销会等待活动会话完全断开后再删除 Keychain 记录，Android 撤销会关闭活动 USB 会话。Slot C 普通 App 首次配对、已配对重连、sandbox 产品认证及需要人工批准安装的真实 Android Keystore 行为均已归档。

**传输功能：**
- 传输丢失重试：现已通过 `RecoveryPolicy` 实现可配置的多尝试恢复队列
  （指数退避、尝试上限、sidecar 守门）。
  - 默认 `--retry-on-transport-loss` 仍复刻历史的单次重试，向后兼容既有真机脚本。
  - `--max-retry-attempts N` 开启最多 N 次额外重连尝试。
  - `--retry-backoff-ms M` 覆盖基准退避（默认 500ms）。
  - 单元测试 + 端到端测试覆盖退避时序、尝试耗尽、本地故障注入服务器的多次断线恢复。
  - Core 已有可选磁盘队列 manifest 与恢复 factory；Mac App 已提供私有的按设备 Application Support 存储位置，通过事务化持久化的 App 自有 bookmark 重新取得 security-scoped 访问，把 bookmark/manifest 健康合并到同一个显式权威重试，并在会话拆除前暂停队列。
- 并发：稳定 M1 probe 与产品异步 core 都已有受限的双流路径
  - open response 和 chunk 按 request/stream ID 路由，并以公平顺序处理
  - Android 对同一会话的上传/下载合计强制最多 2 条活跃传输
  - 本地 TCP 端到端测试已证明 chunk 交错，并在首块 ACK 前验证 heartbeat 仍可响应
  - 重复 transfer ID 会先于流数量上限被拒绝，保证 transfer 级控制始终确定
  - 产品异步 router 已在唯一 reader 下本地交错验证 refill download、预检后的四块 upload window 与 heartbeat
  - 协议取消会唤醒等待中的 upload window，但不关闭会话；后续 heartbeat 已证明会话可复用
  - 产品异步下载在私有串行文件队列写入，final ACK 前保留旧目标、取消时保留 partial，并在接收数据前拒绝变化的 resume offset
  - `AsyncDownloadCoordinator` 已读取 Core 共用 sidecar，通过注入的认证 client factory 重连，并以同一 transfer ID、实际 partial 偏移和已接受源指纹续传；本地 TCP 覆盖会断开首次会话并验证第二次原子完成
  - `AsyncUploadCoordinator` 已完成串行稳定源读取、四块/2MiB refill、逐 ACK sidecar 提交和 app-sandbox/SAF 重连；本地 TCP 覆盖证明从最后 ACK 重放，并在任务取消时保留 checkpoint
  - `AsyncTransferScheduler` 已提供 FIFO、两任务并发上限、buffering-newest queued/running/retrying/pausing/paused/interrupted/终态快照、跨重试单调的接收端确认 bytes/total、两秒时间加权近期吞吐、重试可见性、完成等待、取消和检查点暂停/继续。默认仍为进程内队列；`restoring(...)` 可选启用版本化原子 manifest，在 executor 启动前先落盘 queued→active，只恢复 sidecar 匹配的 download/app-sandbox/SAF 任务，并把包括 MediaStore 在内的不安全 active 工作保留为禁止自动重放的 `interrupted`。排队 pause 是直接挂起；运行中检查点 pause 只关闭自己的 coordinator session，再以同一 job/transfer identity 入队。该本地策略不声称 Android wire upload pause。
  - 双流/混合流 probe 均可由脚本调用；下载与 provider-aware 上传 scheduler 已装配进认证后的视觉 target，具备按设备隔离持久化、App 自有 security-scoped bookmark 租约和按生命周期暂停。Slot C 已归档普通 App 配对/重连/下载，以及 sandbox App 配对/浏览/下载/上传；sandbox 上传恢复记录位于 App 自有的设备队列目录，不再写到只有读取授权的源文件旁。

**测试覆盖：**
- Slot D 设备（NIO N2301，API 34）：广泛覆盖
- Slot A（SHARP 704SH，API 26）：已归档满足槽位要求的 handshake/list 证据；两次满电 100MiB 恢复探针均功能完成，但仍未通过 20 MiB/s 吞吐 gate
- Slot C（MEIZU M20，API 34）：已有 handshake/list、app-sandbox 100MiB 下载/上传恢复吞吐、权限撤销、预期错误、MediaStore fresh-only 上传、sidecar/ACK 丢失恢复、可写 SAF 恢复，以及真机 source 修改/删除拒绝覆盖
- 未归类：Pixel 9 Pro Fold（API 37）已有 20/20 双设备 ADB 路由 smoke，但它不满足 Slot A 的 API 26-29 要求
- 握手稳定性：Slot A、Slot C 和 Slot D 都已有 20/20 运行
- 吞吐量：Slot D 和 Slot C 下载/上传已有通过的 100MiB 探针；Slot A 低于 20 MiB/s gate

### 剩余核心与发布缺口

**核心功能（按 M1 范围）：**
- AOA 传输路径（在 ADB 路径完成 M1 前被阻止）

**已验证产品状态与剩余发布缺口：**
- Slot C 普通与 sandbox 认证 App 的配对/重连、浏览、双向传输、信任撤销和强退后上传恢复均已归档
- bundle 结构/签名、内置 adb 发现、bookmark 生命周期、私有队列存储和断开处理已在本地验证；Developer ID 签名与公证仍暂缓
- 原生 Settings 与隐私受限的显式启用传输通知已实现；安全与破坏性操作保护不提供可关闭开关

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
| USB 插入 ≤5s | ⚠️ 产品轮询与人工 AX runner 已实现，仍需物理测量 | Mac App 前台活跃时每 2 秒执行一次不重入的设备刷新，非活跃时停止轮询；`run-product-usb-insertion-smoke.sh` 测量物理插入到产品 Accessibility 树出现指定名称的时间，但在归档人工插线动作前不会宣称通过 |
| 首次列表 ≤1s（预热） | ✅ Slot A/C/D 通过 | SHARP 704SH Slot A 测得 `elapsed_ms=165`；NIO N2301 Slot D 测得 `elapsed_ms=98`；MEIZU M20 Slot C 测得 `elapsed_ms=84`；命令外层 wall time 单独记录 |
| 100MB 下载 ≥20 MiB/s | ❌ Slot A 低于 gate | Slot C/D 通过：NIO N2301 测得 48.95 MiB/s；MEIZU M20 测得 35.52 MiB/s。SHARP 704SH Slot A 完成恢复下载，首次为 16.64 MiB/s，满电复测为 16.63 MiB/s；对应原始 ADB baseline 为 7.19 和 11.21 MiB/s |
| 100MB 上传 ≥20 MiB/s | ❌ Slot A 低于 gate | Slot C/D 通过：NIO N2301 测得 33.51 MiB/s；MEIZU M20 测得 20.22 MiB/s。SHARP 704SH Slot A 完成恢复上传，首次为 15.20 MiB/s，满电复测为 15.70 MiB/s |
| 下载恢复 | ✅ Slot C 真机 source 修改/删除通过 | 带指纹验证的部分 + 恢复；MEIZU M20 将 app-sandbox source 增加 1 字节后，恢复被 `invalidArgument` / `source fingerprint changed` 拒绝；删除 source 后，恢复被 `notFound` / `app sandbox file is not available` 拒绝；Android 单测也覆盖缺失、变化和不可用 source fingerprint |
| App-sandbox 上传恢复 | ✅ 已实现 | 带截断/重放容忍的部分 + 恢复 |
| Sidecar 传输重试 | ✅ Slot C/D 通过 | 故障注入以 `recovered=true` 通过；Slot C 和 Slot D 日志在使用非默认策略时记录了重试策略 |
| Fresh MediaStore 上传 | ✅ Slot C/D 通过 | Pictures/Movies 集合；MEIZU M20 已记录 fresh 上传和非零 offset 恢复拒绝 |
| Fresh SAF 上传 | ✅ Slot C 通过 | 用户选择的可写根；归档证据后已撤销临时授权并删除测试文件 |
| SAF 上传恢复 | ✅ 已实现 | Transfer-id 隐藏部分文档 |
| 权限拒绝映射 | ✅ Slot C/D 通过 | Media 列表撤销返回 `permissionRequired`；Media 下载中撤销在 Slot D 记录为预期 transport loss，在 Slot C 记录为撤销后仍完成；随后恢复授权 |
| 诊断归因 | ✅ 已实现 | 服务/权限/传输状态 |
| 三设备覆盖 | ❌ 受 Slot A 吞吐阻塞 | 所需 Slot A/C/D 设备现在都有记录，但 Slot A 下载/上传吞吐低于 M1 gate |
| AOA 可行性（2 设备） | ❌ 阻止 | 等待 ADB 路径完成 |

## 即时下一步

### 高优先级（M1 阻塞项）

1. **调查 SHARP 704SH（API 26）上的 Slot A 吞吐：** 充电已不再是待排变量：满电复测下载完成于 16.63 MiB/s（原始 ADB baseline 11.21 MiB/s），上传完成于 15.70 MiB/s，仍低于 20 MiB/s gate。请改用不同的物理 USB 路径（直连主机端口、线缆且不经 Hub）重跑，并再次记录原始 ADB baseline；随后使用第二台 API 26-29 设备交叉验证，再决定是否调整协议假设或门槛。

2. **保持异常/人工场景证据可复现**：Slot C 已归档下载和上传的人工物理 USB 拔线、同设备重连与续传，以及 source 修改和删除拒绝；仅在需要回归证据时重跑专用下载 runner。

### 中优先级（M1 增强）

3. **推广已归档的多流真机证据：**
   - ✅ Slot C MEIZU M20 的 `--dual-download-check` 与
     `--mixed-transfer-check --mixed-upload-destination-path <fresh-target>`
     已在同一 async session 上通过，heartbeat 保持响应且证据已归档
   - 仅在需要区分设备特有行为时把相同 probe 扩展到 Slot A/D；Slot C
     多流证据已不再是开放 gate
   - ✅ 普通 ad-hoc App 的产品认证下载已用 Slot C 可清理数据归档
   - ✅ 已归档 sandbox bundle 下的产品认证 1MiB 下载与上传
   - ✅ sandbox App 强制终止后将上传恢复为暂停状态，重新取得 bookmark，并从 durable checkpoint 完成第 2 次尝试

4. **扩展 SAF 上传测试：**
   - 在多个 OEM 上测试可写 SAF 目录
   - ✅ 本地 writer 测试已验证：不可恢复上传非最终关闭会删除未完成文档，
     可恢复上传会保留隐藏 partial，完成的可恢复上传会重命名且不会删除成品
   - 在多个 OEM 的可写 SAF provider 上重复上述清理/保留场景
   - 记录厂商的 SAF 提供者特性

5. **在签名 sandbox App 中演练持久队列恢复（M1 后证据）：**
   - 归档同一认证设备下可恢复排队传输的重启流程
   - 归档 stale bookmark 刷新与配平的 security-scope release
   - 在可清理状态上确认 `interrupted` 与持久化健康 UI

### 低优先级（M1 后）

6. **USB 时序测量：**
   - 使用需要人工参与的产品 Accessibility runner，不得以 ADB 可见性替代
   - 线缆插入到设备可见的延迟
   - 授权流程时序
   - 拔插后重连

7. **大目录压力测试：**
   - ✅ 本地正确性基线：真实 app-sandbox catalog 将 1005 个文件分页为
     1000 + 5，产品模型连续读取三页共 1205 项后保持顺序、唯一性和正确终止
   - 1000+ 条目的 MediaStore 列表
   - 产品 pager 连续读取多个 1000 条目页面的性能
   - ✅ Slot C app-sandbox provider 端到端分页：可清理的 1005 条目目录在
     833 ms 内返回 1000 + 5 行，只归档聚合证据并确认清理
   - ✅ 本地 Java 内存形态：App Sandbox 流式遍历目录，App Sandbox/SAF
     都最多保留排序前 `offset + pageSize` 个候选；MediaStore 将
     limit/offset/sort 下推给 `ContentResolver`
   - 真机上端到端的 provider 进程内存使用

8. **AOA 路径探索：**
   - 在 ADB 在 3 个设备上通过 M1 后
   - 需要至少 2 个支持 AOA 的设备
   - 吞吐量目标：≥30 MB/s

## 已知限制

- **已有认证持久双向传输产品路径，但还不是完整管理器：** 本地化 SwiftUI target 已具备 serial 脱敏发现、动态 forward、SAS/Keychain 认证、文件浏览、诊断、原生面板、设备隔离队列和 App 自有 bookmark 租约。带 sandbox entitlement 的 bundle 已在 MEIZU M20 上归档配对、浏览、1MiB 双向传输，以及强制终止后恢复 4GiB 上传。压缩本地 DMG、Applications 快捷方式、SHA-256、只读挂载及挂载后 App 复核已实现；Developer ID 签名与公证尚未验证。
- **文件规模之外仍有结构性债务：** 全部手写生产与测试文件均满足默认 800 行预算，所有产品/CLI 网络路径均使用 async transport；文件浏览工具栏、传输持久化映射、transfer frame、scheduler 测试支持及本地 framed-server 的状态/读取器/响应值已有明确边界，贡献与 PR 交接证据由 CI 强制检查，但单一 GitHub owner 的发布权限仍然集中；见[结构性债务基线](technical-debt.md)
- **多流支持范围有限：** 普通 CLI download/upload 仍为单传输；`dual-download-smoke` 与 `mixed-transfer-smoke` 是显式 probe。混合方向及预检后的 4 chunk / 2 MiB upload window 已有本地 TCP、真机脚本入口和 Slot C 归档真机结果；Slot A/D 仅在需要区分设备特性时再扩展。
- **重试默认单次：** `--retry-on-transport-loss` 默认仍只重试一次以保持向后兼容；需显式传 `--max-retry-attempts N` 才启用多尝试恢复队列
- **可恢复 SAF partial 生命周期：** 不可恢复上传非最终关闭会删除未完成文档；
  带 transfer ID 的上传会有意保留隐藏 partial。放弃的可恢复 partial 仍需
  显式清理。
- **MediaStore fresh-only：** 不支持上传恢复（返回 unsupportedCapability）
- **相册首次索引成本：** 为保持 API 26–34 一致语义，首次相册列表会流式扫描 MediaStore bucket 列，但内存只随相册数增长；有界 LRU 会避免每个相册封面重复扫描，服务重启后的旧 token 解析可能再触发一次扫描。
- **仅 ADB loopback：** Android endpoint 拒绝非 127.0.0.1 客户端
- **需要 debug harness Activity：** 某些 OEM 设备在没有前台 Activity 的情况下冻结服务 accept() 线程
- **Android 15 后台服务额度：** ADB loopback endpoint 使用 `dataSync` 前台服务类型，每 24 小时最多在后台运行 6 小时。超时后会关闭 endpoint 并停止 non-sticky service；未来 AOA 路径只有在取得真实 USB accessory grant 后才能使用 `connectedDevice`。

## 测试结果摘要

截至 2026-07-11，`fixtures/m1-runs/` 包含：
- 67 个测试结果日志
- SHARP 704SH（Slot A，API 26）的 handshake/list 和未通过 100MiB 吞吐证据、NIO N2301（Slot D，API 34）的较完整矩阵覆盖、MEIZU M20（Slot C，API 34）的 handshake/list、app-sandbox 吞吐/恢复、权限、预期错误、MediaStore 和恢复证据，以及 Pixel 9 Pro Fold（API 37）的未归类双设备 ADB 路由 smoke
- 覆盖：app-sandbox 上传（fresh/resume/100MB）、app-sandbox 下载恢复/100MB、真机恢复前 app-sandbox source 修改和删除、MediaStore 上传、Media 列表和下载期间权限撤销、预期错误边界、cancel、pause、Slot D 握手稳定性（20/20）、Slot C 握手稳定性（20/20）、Slot D/Slot C 吞吐断言、ADB baseline 下载诊断、可配置恢复策略故障 smoke，以及 app-sandbox ACK 丢失重放
- 通过：Slot D 窗口化下载用 1MiB chunk 测得 48.95 MiB/s，同文件 ADB baseline 为 75.70 MiB/s
- 通过：Slot D 窗口化上传用 1MiB chunk 测得 33.51 MiB/s，通过 20 MiB/s gate
- 通过：Slot D 预热 media-images 列表测得 harness `elapsed_ms=98`，通过 1000 ms gate
- 通过：Slot D Media 权限撤销后 `dm://media-images/` 返回 `permissionRequired`，随后恢复原授权
- 通过：Slot D 在 `dm://media-images/media/1000001148` 下载期间撤销 Media 权限后观测到 `transport_lost_after_revoke`，随后恢复原授权
- 通过：MEIZU M20 Slot C 在 20/20 次 `m1-smoke` 后，预热 media-images 列表测得 harness `elapsed_ms=84`，通过 1000 ms gate
- 通过：MEIZU M20 Slot C app-sandbox 100MiB 下载恢复测得 35.52 MiB/s，ADB baseline 为 36.90 MiB/s
- 通过：MEIZU M20 Slot C app-sandbox 100MiB 上传恢复在 Mac harness send-limit 修复后测得 20.22 MiB/s
- 通过：MEIZU M20 Slot C 在 ACK 驱动持续补帧后，不可压缩 100MiB app-sandbox 上传分别测得 256KiB chunk 32.73 MiB/s、512KiB chunk 35.29 MiB/s、1MiB chunk 22.77 MiB/s；恢复、传输中断重试和 ACK 丢失重放也分别以 36.20、34.33、35.04 MiB/s 通过
- 通过：MEIZU M20 Slot C 可写 SAF 根目录的 10MiB 不可压缩上传恢复测得 27.36 MiB/s；传输中断首次暴露 provider partial 超前于 Mac 持久 ACK，加入 seekable partial 截断后以 `recovered=true`、27.14 MiB/s 通过，随后撤销授权并删除专用测试目录
- 通过：MEIZU M20 Slot C Media 权限撤销后 `dm://media-images/` 返回 `permissionRequired`，随后恢复原授权
- 通过：MEIZU M20 Slot C 预期错误边界：缺失 SAF root 和缺失 app-sandbox 下载源均返回 `notFound`
- 通过：MEIZU M20 Slot C MediaStore fresh 上传成功，且非零 offset 上传恢复返回 `unsupportedCapability`
- 通过：MEIZU M20 Slot C app-sandbox 上传 ACK 丢失重放以 `recovered=true` 恢复
- 通过：MEIZU M20 Slot C app-sandbox 100MiB 下载故障重试以 `recovered=true` 恢复
- 通过：MEIZU M20 Slot C 在 `dm://media-images/media/1000000054` 下载期间撤销 Media 权限后仍完成下载，随后恢复原授权
- 通过：MEIZU M20 Slot C 在 262144 字节部分下载后，将脚本创建的 1MiB app-sandbox source 修改为 1048577 字节；恢复正确返回 `invalidArgument` / `source fingerprint changed`，设备和 Mac 临时文件均已清理
- 通过：MEIZU M20 Slot C 在 262144 字节部分下载后删除脚本创建的 1MiB app-sandbox source；恢复正确返回 `notFound` / `app sandbox file is not available`，设备和 Mac 临时文件均已清理
- 通过：SHARP 704SH Slot A 握手稳定性 20/20 通过，预热 `dm://media-images/` 列表测得 `elapsed_ms=165`
- 未通过：SHARP 704SH Slot A app-sandbox 100MiB 下载恢复完成，但吞吐为 16.64 MiB/s，低于 20 MiB/s gate；原始 ADB baseline 为 7.19 MiB/s
- 未通过：SHARP 704SH Slot A app-sandbox 100MiB 上传恢复完成，但吞吐为 15.20 MiB/s，低于 20 MiB/s gate
- 未通过，满电复测：SHARP 704SH Slot A app-sandbox 100MiB 下载恢复完成，吞吐为 16.63 MiB/s，低于 20 MiB/s gate；原始 ADB baseline 为 11.21 MiB/s
- 未通过，满电复测：SHARP 704SH Slot A app-sandbox 100MiB 上传恢复完成，吞吐为 15.70 MiB/s，低于 20 MiB/s gate
- 通过：Pixel 9 Pro Fold API 37 未归类 smoke 在两台 ADB 设备同时连接时通过显式 serial 路由完成 20/20 次尝试
- 单测覆盖异常路径：stale 下载恢复 source fingerprint、invalid page token、oversized envelope、bad transfer-chunk CRC32
- 通过：MEIZU M20 Slot C 在 2GiB app-sandbox 上传至 768081920 字节持久 ACK 后物理拔线；重新插入、授权、重启 Activity 并重建动态 ADB forward 后，从同一 sidecar 恢复剩余 1379401728 字节，最终设备文件为 2147483648 字节
- 通过：Slot C 普通 ad-hoc 产品 App 可见 SAS 配对、新鲜认证、Keychain 重连、跨越旧 30 秒边界的四次 heartbeat、认证 app-sandbox 列表、原生队列 1MiB 下载与清理
- 通过：Slot C sandbox 产品 App 完成可见 SAS 认证、app-sandbox listing、目录授权的 1MiB 下载、App 自有恢复记录的 1MiB 上传、双向 hash 对账与清理
- 通过：Slot C sandbox App 在 4GiB 上传期间被 `SIGKILL` 后恢复为显式暂停任务，重新取得源文件 bookmark，从 598999040 字节开始第 2 次尝试，最终 hash 一致并清理恢复状态
- 通过：MEIZU M20 Slot C 在 10GiB app-sandbox 下载持久 partial 达到 3626762240 字节后物理断线；同一 serial 以新 transport identity 重连，并以 28.35 MiB/s 恢复剩余 7110656000 字节至精确最终大小
- 缺失：Slot A 通过不同物理 USB 路径或第二台 API 26-29 设备获得的吞吐通过证据

## 参考文档

- [M1 测试指南](m1-testing-guide-zh.md)：分步测试说明
- [M1 设备矩阵](m1-device-matrix.md)：所需设备和通过标准
- [M0 收口](m0-closeout.md)：规格决策
- [协议运行时](protocol-runtime.md)：并发限制和反压
- [协议](protocol.md)：消息模式和语义
- [路径模型](path-model.md)：逻辑路径抽象
