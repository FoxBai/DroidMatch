# M1 测试指南

本指南提供运行 M1 设备测试的分步说明，这些测试满足 `docs/m1-device-matrix.md` 中定义的退出标准。

## 前置要求

- 一个或多个物理 Android 设备（见下面的设备要求）
- USB 线缆连接且设备已通过 `adb devices -l` 授权
- 开发者选项必须允许通过 ADB 安装应用。部分 OEM 会把这个开关命名为
  “通过 USB 安装”、“USB 安装”或“USB 调试（安全设置）”；安装 debug APK 时请保持设备解锁。
- 已安装 Debug APK（`tools/run-m1-device-smoke.sh` 会自动处理安装）

如果已安装 `adb` 但不在 `PATH` 中，可以导出 `DROIDMATCH_ADB`，或给快速场景包装脚本传入 `--adb`：

```bash
tools/quick-test-scenarios.sh handshake-stability \
  --adb "$HOME/Library/Android/sdk/platform-tools/adb" \
  --serial <serial> \
  --device-slot D \
  --max-list-ms 1000
```

`tools/run-m1-device-smoke.sh` 也会从 `$ANDROID_HOME`、`$ANDROID_SDK_ROOT` 或
`~/Library/Android/sdk` 自动发现 `adb`。

如果安装失败并显示 `INSTALL_FAILED_USER_RESTRICTED`，说明手机正在阻止 ADB 安装。
请重新打开开发者选项，启用上面提到的 USB 安装/安全开关，然后重新运行 smoke 命令。
除非要记录厂商特定阻塞，否则不要为这种环境配置失败提交结果日志。
部分 Flyme 版本还会为每次测试 APK 安装显示手机端确认弹窗。用户明确点按“允许”后
Keystore runner 可以通过；此类证据需要人在场，不能描述为无人值守真机运行。

## 设备要求

M1 需要至少三个物理设备，覆盖这些槽位：

| 槽位 | Android API | 设备类型 | 用途 |
|---|---|---|---|
| A | API 26-29 | 传统存储时代手机 | 验证最低支持版本的 SAF/MediaStore 行为 |
| C | API 33-35 | 最新主流手机 | 验证当前权限提示和 AOA 可行性 |
| D | API 30+ | 非 Google OEM 或平板 | 验证厂商 USB 行为和大容量存储 |

当前测试覆盖：
- ✅ Slot D: NIO N2301, API 34（已记录多个测试）
- ⚠️ Slot A: SHARP 704SH, API 26 已有 20/20 握手和预热 media-images 列表证据；已归档的 100MiB 下载/上传恢复探针使用旧 debug/Onone Mac harness，且早于当前传输优化，因此低于 20 MiB/s 的数值只是历史诊断，两个方向都需要用 release 配置重跑
- ✅ Slot C: MEIZU M20, API 34 已有 20/20 握手、预热 media-images 列表、app-sandbox 100MiB 下载/上传恢复吞吐、权限撤销、预期错误、MediaStore fresh-only 上传、恢复、真机 source 修改/删除拒绝、可写 SAF、需要人工参与的物理 USB 上传与 10GiB 下载拔线/重连/续传，以及需要人工批准安装的 Keystore 证据
- ℹ️ 未归类：Pixel 9 Pro Fold, API 37 已有 20/20 双设备 ADB 路由 smoke；它不满足 Slot A API 26-29 要求

### 可选：配对 Keystore instrumentation

常规 CI 只编译、不执行隔离的 Android Keystore 测试。在明确选定可写测试设备后运行：

```bash
tools/run-android-keystore-instrumentation.sh --serial <serial>
```

不要在 OEM 真机上改用 Gradle `connectedDebugAndroidTest`。厂商安装器可能先删除产品包，
随后又因策略拒绝测试 APK，造成产品私有测试数据丢失且测试根本没有执行。仓库 runner
会先构建两个 APK、要求产品包已存在、先安装测试 APK、运行隔离 runner，最后只删除
`app.droidmatch.test`；如果安装被拒绝，它会保留产品包与数据并退出。

`PairingKeystoreInstrumentationTest` 会创建唯一的测试 alias 与 preferences，验证
P-256 identity 和 AES wrapping 私钥材料不可导出、签名与加密 record 可重开，
并在 `finally` 中删除测试状态。只有这条命令在设备上实际通过后才能记录为真机证据；
仅 APK 编译成功不算证据。

### 需要人工参与的产品 USB 插入时延

在 clean current `origin/main` 上构建并启动唯一一个 release 产品 App，保持 App 在前台，
物理断开所选设备并确认型号卡片已经消失。下面命令使用普通 bundle；若验证 sandbox
variant，则构建时加 `--sandboxed`，runner 再加 `--sandboxed-app`。runner 只读取 macOS
Accessibility 树，不会用 ADB 状态代替产品可见性：

```bash
tools/build-mac-app.sh \
  --configuration release \
  --output mac/.build/product-usb/DroidMatch.app

open mac/.build/product-usb/DroidMatch.app

tools/run-product-usb-insertion-smoke.sh \
  --expected-label 'MEIZU M20' \
  --device-slot C \
  --expected-main-sha <40位-origin-main-SHA> \
  --app-bundle mac/.build/product-usb/DroidMatch.app \
  --result-log fixtures/product-usb-insertion/<timestamp>-slot-c.md
```

等待刚启动的 App 进入前台活跃状态。若 macOS 提示，请给发起命令的 Terminal/Codex 进程
授予 Accessibility 权限。回车只用于
布防固定三秒倒计时，期间不要提前插线。runner 再次确认卡片仍不存在后，会先读取单调时钟，
再打印 `INSERT NOW`；看到信号后再插线。完成时必须恰好一个卡片带共享发现 identifier，
并含精确型号 component 与精确 `ADB` component。随后 runner 才生成新 challenge，必须
通过 controlling terminal 输入界面显示的 `INSERTED <challenge>`，明确确认真实物理插线
动作；pipe 或提前提交的输入不能生成正式证据。

正式发布还要求运行中的 App 唯一且 canonical path 等于 `--app-bundle`，bundle/签名/
entitlement 校验通过、配置为 release、内嵌 clean 完整 SHA 与运行前后两次 fresh
current-main 相等，并记录 bundle executable SHA-256，同时要求 Security.framework
读取磁盘 bundle code cdhash，并让 Security.framework 直接验证动态 guest 满足绑定
该 hash 的 requirement。只有 staged fixture 通过
`check-product-usb-insertion-logs.sh --log` 的结构与隐私校验后才原子创建。受信任历史、
文件名、部分型号匹配、重复卡片、fake probe、提前插线、App 缺失/不在前台、权限缺失、
确认短语错误或超过 5 秒都会 fail closed。自动化只能证明 App/AX 状态、时间与 artifact
身份；现场操作者仍必须对真实断开/插入负责。离线覆盖位于两个 product USB test 脚本，
永远不算真机证据。

### 需要人工参与的物理下载断线与续传

只在明确选定的可写测试设备上运行专用 runner，并确保 debug 产品已安装。它不会安装
APK，也不会删除调用者指定的目标文件：

```bash
tools/run-download-unplug-device-smoke.sh \
  --serial <serial> \
  --source-path dm://app-sandbox/<large-test-file> \
  --expected-bytes <精确字节数> \
  --destination /tmp/droidmatch-download-unplug.bin
```

只在看到 `UNPLUG NOW` 后物理拔线；脚本报告持久 partial 后，再连接同一设备。通过结果
证明指定 serial 确实离开 ADB、非空 partial 与 checkpoint 得以保留、同一 serial 重新
进入 ready、`download --resume` 完成、最终大小精确匹配，且两个脚本自建 forward 均已
清理。runner 不会自动归档证据；加入真机 fixture 前必须人工审查并脱敏终端输出。
无需硬件的状态机覆盖由 `tools/test-download-unplug-device-smoke.sh` 提供。

## 关键 M1 退出标准测试

同一组检查也可以通过快速场景包装脚本运行：

```bash
tools/quick-test-scenarios.sh help
tools/quick-test-scenarios.sh handshake-stability --serial <serial> --device-slot D --max-list-ms 1000
tools/quick-test-scenarios.sh full-matrix --serial <serial> --device-slot D
```

`full-matrix` 是为兼容性保留的场景名，只运行自动化 core ADB matrix：稳定性、
吞吐量、续传、重试和权限检查。它本身不能满足全部 M1 退出标准，也不包含需要人工参与
的产品 App 发现/连接与 SAS 确认、SAF 授权，以及物理拔线/重连恢复等补充真机步骤。
请按上文和 `docs/m1-device-matrix.md` 另行完成这些真机流程。

设备 runner 会以 Swift release 配置构建并调用 `droidmatch-harness`。debug/Onone
`swift run` 测量使用不同的主机执行模式，只能用于诊断，不能判定当前 20 MiB/s 下载或
上传 gate 通过或失败。

当前开放的 Slot A gate 应使用版本化严格 wrapper，不要把两条松散命令手工拼成归档：

```bash
tools/run-m1-throughput-gate.sh \
  --serial <serial> \
  --expected-main-sha <40位-origin-main-SHA>
```

在任何构建或设备写入前，wrapper 会 fetch `origin/main`，并要求其完整 SHA、本地 HEAD
与人工核对后传入的 SHA 在 clean worktree 中完全一致；设备必须为 API 26–29。随后一次
fresh profile 同时验证 raw ADB baseline、双向精确 104857600 字节、请求和实际协商
1048576 字节 chunk、双向至少 20 MiB/s；创建文件前还会预留并验证高熵 app-sandbox
source/final/partial 名称均不存在。只有 prepared source、上传 final/隐藏 partial、
本地 transfer 产物和 owned ADB forward 都确认不存在，并在结束时再次 fetch 证明
`origin/main` 未前进后，才发布脱敏
`m1-adb-throughput-v1` fixture。离线 profile 测试使用 fake ADB/runner，不是真机证据。

### 1. 握手稳定性测试

**目标：** 验证 ADB 握手在 20 次尝试中至少成功 19 次。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --handshake-attempts 20 \
  --min-handshake-passes 19 \
  --list-path dm://media-images/ \
  --max-list-ms 1000
```

**预期结果：**
- 脚本输出显示 `handshake attempts: 19-20/20 passed`（至少 19 次）
- 首次目录列表报告的 harness `elapsed_ms` ≤ 1000（对于预热服务）。结果日志也会单独记录命令外层 wall time；gate 使用 harness elapsed time，避免 SwiftPM/进程启动开销污染设备延迟断言。如果失败，保留结果日志并把它当作延迟问题处理，而不是握手问题。
- 结果日志写入 `fixtures/m1-runs/`

### 2. 下载吞吐量测试

**目标：** 验证 100MB ADB 下载吞吐量 ≥ 20 MiB/s。

**设置：**
首先，在 app sandbox 中准备一个 100MB 测试文件：
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-100mb-zero.bin \
  --adb-baseline-download-check \
  --resume-check \
  --chunk-size-bytes 1048576 \
  --min-download-mib-per-second 20
```

**作用：**
- 在 `dm://app-sandbox/dm-100mb-zero.bin` 创建 100MiB 零填充文件
- 记录同一 app-sandbox 文件的原始 ADB `exec-out run-as ... cat` 下载基线
- 运行故意部分下载，然后恢复
- 使用 1MiB 块（Android 当前协商的最大值）
- 断言吞吐量 ≥ 20 MiB/s
- 在结果日志中记录 `elapsed_ms` 和 `throughput_mib_per_sec`

**预期结果：**
- 下载完成，`throughput_mib_per_sec` ≥ 20.0
- 结果日志包含 M1 计时指标和 ADB baseline 下载吞吐
- 测试在同一组三台已选必测设备（Slot A、Slot C、Slot D/E 各一台）上通过

### 3. 上传吞吐量测试

**目标：** 验证 100MB app-sandbox ADB 上传吞吐量 ≥ 20 MiB/s。

**设置：**
创建本地 100MB 测试文件：
```bash
dd if=/dev/zero of=/tmp/droidmatch-100mb-upload.bin bs=1048576 count=100
```

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-100mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
  --min-upload-bytes 104857600 \
  --chunk-size-bytes 1048576 \
  --min-upload-mib-per-second 20 \
  --cleanup-upload-destination
```

**预期结果：**
- 上传完成且 `throughput_mib_per_sec` ≥ 20.0
- 结果日志包含 `elapsed_ms` 和 `throughput_mib_per_sec`
- 测试在与下载 gate 相同的三台已选必测设备上通过
- 清理自动删除上传的文件

### 4. 下载恢复测试

**目标：** 验证中断的下载从已接受的偏移量恢复，无数据损坏。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-100mb-zero.bin \
  --resume-check \
  --chunk-size-bytes 1048576
```

**作用：**
- 部分下载（默认：停在 1 字节后）
- 创建带源指纹的 sidecar
- 从部分偏移量恢复
- 验证最终文件完整性

**预期结果：**
- 部分下载留下 `.droidmatch-part` 和 `.droidmatch-transfer.json`
- 恢复命令成功完成，`final_offset=104857600`
- 无数据损坏

### 4a. 下载恢复前 source 修改测试

**目标：** 验证部分下载 sidecar 已生成后，真机 source 发生变化时恢复请求会被拒绝。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-source-mutation.bin \
  --prepare-app-sandbox-bytes 1048576 \
  --resume-check \
  --partial-bytes 262144 \
  --download-resume-source-mutation-check
```

**作用：**
- 仅修改本脚本在 `dm://app-sandbox/` 创建的零填充文件；不会修改用户文件或 MediaStore 内容
- 停止部分下载后，在恢复请求前向准备好的 source 追加 1 个字节
- 要求远端返回 `invalidArgument` 和 `source fingerprint changed`
- 退出时删除准备好的 source，以及 Mac 上的部分文件和 sidecar

**预期结果：**
- 结果日志记录 source 修改前后的大小和预期的指纹拒绝
- 该场景本身通过，因为被拒绝正是所要求的行为

### 4b. 下载恢复前 source 删除测试

**目标：** 验证部分下载 sidecar 已生成后，真机 source 被删除时恢复请求返回 not-found。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-source-deletion.bin \
  --prepare-app-sandbox-bytes 1048576 \
  --resume-check \
  --partial-bytes 262144 \
  --download-resume-source-deletion-check
```

**作用：**
- 仅删除本脚本在 `dm://app-sandbox/` 创建的零填充文件；不会删除用户文件或 MediaStore 内容
- 停止部分下载后，在恢复请求前删除准备好的 source，并验证其已不存在
- 要求远端返回 `notFound` 和 `app sandbox file is not available`
- 退出时删除 Mac 上的部分文件和 sidecar

**预期结果：**
- 结果日志记录受控删除和预期的 not-found 拒绝
- 该场景本身通过，因为被拒绝正是所要求的行为

### 4c. 双下载流测试

**目标：** 验证同一设备会话中的两条下载流可同时保持活跃、chunk 能独立路由，且控制平面仍可响应。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-dual-stream.bin \
  --prepare-app-sandbox-bytes 1048576 \
  --dual-download-check \
  --chunk-size-bytes 262144
```

**作用：**
- 创建一个可清理的 app-sandbox source，并为它打开两个独立 reader
- 在任一首块被 ACK 前先打开两条传输
- 要求两条流活跃期间 heartbeat 仍能响应
- 独立路由和校验每条流，随后也执行普通 download gate
- 退出时删除脚本创建的 Android source 和本地下载产物

**预期结果：**
- Harness 输出包含 `dual-download-smoke passed`
- 结果日志记录两条 stream ID、chunk/字节总数和 heartbeat 值

### 4d. 上传/下载混合流测试

**目标：** 让产品异步混合方向路径可直接在真机调用：下载、fresh 上传和
heartbeat 在两条 transfer stream 都 open 后共享同一会话。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-mixed-download.bin \
  --prepare-app-sandbox-bytes 1048576 \
  --upload-source /tmp/dm-mixed-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-standalone-upload.bin \
  --mixed-transfer-check \
  --mixed-upload-destination-path dm://app-sandbox/dm-concurrent-upload.bin \
  --chunk-size-bytes 262144 \
  --cleanup-upload-destination
```

**作用：**
- 先 open 一条下载和一条不同目标的上传，再启动两边文件操作
- 在下载仍未 ACK、上传尚未发 chunk 时要求 heartbeat 往返，再通过异步唯一 reader router 并发执行原子下载和 4 chunk / 2 MiB 上传 refill
- final ACK 后重新校验本地上传源，并把报告字节数与两侧本地文件核对
- wire 上使用不透明的上传源标签，不把 Mac 路径或真实文件名复制到远端诊断
- 同一轮仍运行普通下载/上传检查；standalone 与并发上传目标必须不同

**预期结果：**
- Harness 输出包含 `mixed-transfer-smoke passed`
- 结果日志记录两条不同的 stream ID、双方 chunk/字节总数和 heartbeat 值
- 该改动只让 probe 可执行；归档脱敏真机运行前仍不能声称已有设备证据

### 5. 上传恢复测试

**目标：** 验证中断的 app-sandbox 上传恢复并提交最终目标。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-100mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
  --upload-resume-check \
  --upload-partial-bytes 1048576 \
  --chunk-size-bytes 1048576 \
  --cleanup-upload-destination
```

**作用：**
- 部分上传（停在 1MiB 后）
- 创建 `.droidmatch-upload-transfer.json` sidecar
- 从部分偏移量恢复
- 验证 Android 提交最终文件

**预期结果：**
- 部分上传创建 Android 隐藏 `.droidmatch-upload-part`
- 恢复完成，`final_offset=104857600`
- Android 原子替换目标文件

### 6. 传输丢失恢复测试

**目标：** 验证基于 sidecar 的重试在传输丢失后重新连接。

**带故障注入的下载：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-100mb-zero.bin \
  --resume-check \
  --download-retry-fault-check \
  --chunk-size-bytes 1048576 \
  --max-retry-attempts 3 \
  --retry-backoff-ms 100
```

**带故障注入的上传：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-100mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
  --upload-resume-check \
  --upload-retry-fault-check \
  --chunk-size-bytes 1048576 \
  --max-retry-attempts 3 \
  --retry-backoff-ms 100 \
  --cleanup-upload-destination
```

**作用：**
- 通过 `tools/m1-fault-proxy.py` 路由传输
- 代理在第 3 个服务器帧后断开首次传输连接
- Mac harness 检测丢失并使用 sidecar 重试；不传 `--max-retry-attempts`
  时保持历史单次重试，上面的示例会把可配置恢复队列策略写进结果日志
- 要求最终输出包含 `recovered=true`

**预期结果：**
- 尽管注入断开，传输仍完成
- Harness 输出包含 `recovered=true`
- 展示对线缆拔插的弹性

### 7. 上传 ACK 丢失恢复测试

**目标：** 验证 app-sandbox 上传通过截断和重放容忍 ACK 丢失。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-10mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-10mb-upload-ack-loss.bin \
  --upload-resume-check \
  --upload-retry-ack-loss-check \
  --chunk-size-bytes 1048576 \
  --cleanup-upload-destination
```

**作用：**
- 通过丢弃第一个 ACK 的代理路由上传
- Android 写入块但 Mac 不推进偏移量
- Mac 重试，Android 将部分截断回确认的偏移量
- 验证接受重复块

**预期结果：**
- 尽管第一个 ACK 丢失，上传仍完成
- 展示 Android 写入和 Mac ACK 之间的窗口容忍度

### 8. 权限撤销测试

**目标：** 验证 media root 列表在撤销后返回 `permissionRequired`。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --media-permission-revoked-check \
  --list-path dm://media-images/
```

**作用：**
- 记录当前 media 权限
- 撤销 `READ_MEDIA_IMAGES`、`READ_MEDIA_VIDEO` 和相关权限
- 要求 `list-dir dm://media-images/` 返回错误码 `permissionRequired`
- 测试后恢复原始权限

**预期结果：**
- ListDir 在撤销期间失败，返回 `ERROR_CODE_PERMISSION_REQUIRED`
- 权限自动恢复
- Android endpoint 可能需要在恢复后重启

**MediaStore 下载期间撤销：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --source-path dm://media-images/media/<id> \
  --destination /tmp/droidmatch-media-revoke-during-download.jpg \
  --chunk-size-bytes 1048576 \
  --media-permission-revoked-during-download-check
```

**作用：**
- 通过本地 frame-aware fault proxy 路由 media 下载
- 在前几个 proxied 下载 chunk 后撤销当前 media 读取权限
- 接受完整下载，或预期内的 transport-loss 错误
- 检查后恢复原始 media 授权

**预期结果：**
- 当前 Slot D NIO N2301 记录为 `transport_lost_after_revoke`
- 日志包含权限变更、fault-proxy hook status 和恢复输出
- 不要把这个检查和吞吐/最小字节 gate 混用；此运行验证权限变化行为，不验证完整文件传输性能

### 9. 预期错误边界测试

**目标：** 记录缺失源、未授权根和不支持操作的稳定错误映射。

**列出缺失的 SAF 根：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --list-expect-error-path dm://saf-missing/ \
  --list-expect-error-code notFound
```

**下载缺失文件：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --download-open-expect-error-path dm://app-sandbox/missing-file.bin \
  --download-open-expect-error-code notFound
```

**MediaStore fresh-only 上传恢复：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-upload.jpg \
  --upload-destination-path dm://media-images/droidmatch-test.jpg \
  --upload-resume-unsupported-check \
  --min-upload-bytes 1 \
  --cleanup-upload-destination
```

**预期结果：**
- 每个测试记录预期的错误码和可选消息子串
- 证明协议为明确定义的失败案例返回稳定的类型化错误

## 测试矩阵建议

对于跨三个设备的完整 M1 验证：

1. **Slot A 设备（API 26-29）：**
   - 握手稳定性（20 次尝试）
   - 100MB 下载吞吐量
   - 100MB 上传吞吐量
   - 下载恢复
   - 上传恢复

2. **Slot C 设备（API 33-35）：**
   - 与 Slot A 相同，加上：
   - 权限撤销测试
   - MediaStore 下载期间权限撤销
   - 预期错误边界
   - Fresh MediaStore 上传
   - 传输丢失恢复
   - 下载恢复前 app-sandbox source 修改拒绝
   - 下载恢复前 app-sandbox source 删除拒绝

3. **Slot D 设备（国产 OEM 或平板）：**
   - 握手稳定性
   - 大目录列表（如果可用）
   - 100MB 吞吐量测试
   - 厂商特定行为验证

## 结果日志

所有测试将脱敏后的日志写入 `fixtures/m1-runs/`，除非传递 `--no-result-log`。

提交日志前：
```bash
bash tools/check-m1-run-logs.sh
```

这确保日志不包含：
- 完整设备序列号（应该脱敏）
- 个人文件路径
- 未脱敏的支持包

## 当前测试覆盖状态

基于 `fixtures/m1-runs/` 中的现有日志和自动化测试：
- ✅ App-sandbox 上传（fresh、resume、100MB）
- ✅ 下载 cancel 和 pause
- ✅ MediaStore 上传 fresh-only 边界
- ✅ Slot D 握手稳定性（NIO N2301 20/20 次尝试）
- ✅ 带 `recovered=true` 的传输丢失恢复
- ✅ Slot D ADB baseline 下载诊断（同一个 100MiB app-sandbox 文件达到 75.70 MiB/s）
- ✅ Slot D 100MB 窗口化下载断言（1MiB chunk 下 48.95 MiB/s，高于 20）
- ✅ Slot D 100MB 窗口化上传断言（1MiB chunk 下 33.51 MiB/s，高于 20）
- ✅ Slot D 预热 media-images 列表断言（harness `elapsed_ms=98`，低于 1000）
- ✅ Slot D Media 权限撤销（`permissionRequired`，并恢复原授权）
- ✅ Slot D MediaStore 下载期间权限撤销（`transport_lost_after_revoke`，并恢复原授权）
- ✅ Slot A SHARP 704SH 握手稳定性（20/20 次尝试）和预热 media-images 列表断言（`elapsed_ms=165`，低于 1000）
- ⚠️ Slot A SHARP 704SH 100MiB 下载历史诊断：首次恢复下载完成于 16.64 MiB/s（原始 ADB baseline 为 7.19 MiB/s）；满电复测完成于 16.63 MiB/s（原始 ADB baseline 为 11.21 MiB/s）。两次都使用旧 debug/Onone harness，不能判定 current-tip 通过或失败
- ⚠️ Slot A SHARP 704SH 100MiB 上传历史诊断：首次恢复上传完成于 15.20 MiB/s；满电复测完成于 15.70 MiB/s，使用同一过时执行路径
- ✅ Slot C MEIZU M20 app-sandbox 100MiB 下载恢复断言（1MiB chunk 下 35.52 MiB/s，高于 20；ADB baseline 为 36.90 MiB/s）
- ✅ Slot C MEIZU M20 app-sandbox 100MiB 上传恢复断言（1MiB chunk 下 20.22 MiB/s，高于 20）
- ✅ Slot C MEIZU M20 Media 权限撤销（`permissionRequired`，并恢复原授权）
- ✅ Slot C MEIZU M20 预期错误边界（缺失 SAF root 和缺失 app-sandbox 下载源均返回 `notFound`）
- ✅ Slot C MEIZU M20 MediaStore fresh-only 上传边界（非零 offset 返回 `unsupportedCapability`，随后 fresh 上传成功并清理）
- ✅ Slot C MEIZU M20 app-sandbox 上传 ACK 丢失重放（`recovered=true`）
- ✅ Slot C MEIZU M20 app-sandbox 下载故障重试（`recovered=true`，100MiB final offset）
- ✅ Slot C MEIZU M20 MediaStore 下载期间权限撤销（`completed_after_revoke`，并恢复原授权）
- ✅ Slot C MEIZU M20 下载恢复前 app-sandbox source 修改（1MiB source 在 262144 字节部分下载后变为 1048577 字节；恢复返回 `invalidArgument` / `source fingerprint changed`，并完成清理）
- ✅ Slot C MEIZU M20 下载恢复前 app-sandbox source 删除（1MiB source 在 262144 字节部分下载后被删除；恢复返回 `notFound` / `app sandbox file is not available`，并完成清理）
- ✅ 未归类 Pixel 9 Pro Fold API 37 双设备 ADB 路由 smoke（显式 serial 下 20/20 次尝试）
- ✅ Android 单测覆盖下载恢复时 source fingerprint 缺失、变化、不可用的拒绝路径
- ✅ `mixed-transfer-smoke` 本地 TCP 覆盖：两方向同时 open、原子下载、四块上传 refill、heartbeat、稳定源复验和不透明上传源标签
- ✅ Android 单测覆盖 invalid 和 query-mismatched page token 拒绝路径
- ✅ Mac/Android 单测覆盖 oversized envelope 拒绝路径
- ✅ Mac/Android 单测覆盖 bad transfer-chunk CRC 拒绝路径
- ❌ **阻塞：** Slot A API 26 仍缺 current-tip、release 配置下的下载/上传 ≥20 MiB/s 证据；需要经直连物理 USB 路径重跑。第二台 API 26-29 设备只是在修改协议假设或阈值前建议执行的非阻塞交叉验证
- ❌ **阻塞：** 每台已选必测 Slot A/C/D 设备都仍缺产品 USB 插入 ≤5 秒的人工归档证据
- ✅ Slot C 可写 SAF root 列表、10MiB 上传恢复与 transport-loss 恢复已归档，并清理授权与测试文件
- ✅ Slot C 2GiB app-sandbox 上传期间物理拔线、重新授权、新 forward 与跨会话恢复已归档
- ✅ Slot C 在 10GiB app-sandbox 下载期间人工物理拔线。指定 serial 在
  3626762240 字节持久 partial 后从 ADB 消失，以新 transport identity 重连，
  并以 28.35 MiB/s 恢复剩余 7110656000 字节。最终大小精确为
  10737418240 字节，原子 checkpoint 和 runner 自建 forward 均完成清理。
- ✅ Slot C `--dual-download-check` 与 `--mixed-transfer-check` 真机输出已归档
- ✅ Slot C MEIZU M20 可清理 app-sandbox 大目录 probe 已归档：1,005 个空条目
  在 833 ms 内分页为 1,000 + 5，只输出聚合结果，并在退出时删除生成目录与
  dynamic forward。可用 `tools/run-large-directory-device-smoke.sh --serial <serial>` 重跑；
  加上 `--measure-memory` 可在 provider 分页时仅采样 App 聚合 PSS。`dumpsys` 会扰动请求，
  因此该诊断运行的耗时不能作为门禁证据。
- ✅ Slot C 内存诊断在分页 1,005 个条目时观察到 App 聚合 PSS 从 31,664 KiB
  上升到 38,313 KiB 的采样峰值。6,649 KiB 增量是进程级真机证据，不是 heap
  allocation 证明或通用上限；runner 已验证其精确目录和 forward 不再存在。
- ✅ Slot C 普通 ad-hoc 产品 App 的可见 SAS 配对、Keychain 重连、空闲 heartbeat、认证浏览与原生队列 1MiB 下载已归档
- ✅ Slot C sandbox 产品 App 已归档可见 SAS 配对、认证浏览、显式目录授权下的 1MiB 下载、App 自有队列 checkpoint 下的 1MiB 上传，以及强退后从 durable checkpoint 恢复 4GiB 上传；双向文件均完成完整性校验并清理测试数据

## 下一步

剩余优先真机测试：

1. 通过直连物理 USB 路径（主机端口、线缆且不经 Hub）用 release 配置重跑 Slot A 双向吞吐并记录原始 ADB baseline。第二台 API 26-29 设备是修改协议假设或阈值前建议执行的非阻塞交叉验证。
2. 在同一组三台已选必测 Slot A/C/D 设备上分别归档人工产品 USB 插入 ≤5 秒证据；ADB 可见不能替代产品 App 可见性。

Slot C 需要人工参与的下载拔线场景已经归档；剩余 M1 真机阻塞项是 Slot A current-tip
吞吐证据和三台必测设备的产品 USB 插入时延证据。

通过 Slot A gate 后才能满足 `docs/m1-device-matrix.md` 中定义的 M1 退出标准。
