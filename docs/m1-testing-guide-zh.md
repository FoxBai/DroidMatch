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

### 704SH 紧凑 launcher 布局诊断

`DroidMatchActivityLayoutInstrumentationTest` 只有在调用方显式传入版本化
`slot-a-704sh-layout-v2` profile 时才会执行。该 profile 会 fail closed 要求目标为
API 26 的 704SH、物理屏幕 720×1280、App viewport 720×1136、320 dpi、en-US 资源且
系统字体缩放为 1.3；测试通过
唯一资源 ID 定位安全 USB 操作，要求英文标签实际占用至少两行，再验证首个操作完整处于
初始 viewport 内、两组并排操作共同采用较高标签的高度，并逐项核对所有可见按钮的实测文字
高度加 compound padding 不超过控件高度。测试还会滚到页面末尾，要求最终“添加文件夹”操作
完整处于系统导航区上方。`DroidMatchScreen` 主层级拥有的全部 `TextView`（包括其按钮）
还必须报告 simple line breaking 且关闭自动连字符，避免 API 26 把本地化字符串中不存在的
连字符渲染出来；系统创建的对话框 view 不在这项检查范围内。
仅覆盖初始 viewport 的 v1 诊断已被取代，不能满足 v2。

在明确选定的设备上使用专用 runner：

```bash
tools/run-704sh-layout-instrumentation.sh --serial <serial>
```

runner 要求产品包已经存在，并拒绝接管预先存在的测试包。它会先构建两个 APK，先尝试
容易受 OEM 策略影响的测试 APK 安装；只有这一步成功后，才通过 `adb install -r` 保留
私有数据覆盖产品 debug APK。测试包采用仅新建安装；若并发或失败后的包所有权不明确，
脚本会保留该包而不接管清理。只有明确安装成功后，此后退出路径才移除
`app.droidmatch.test`，还会确认
产品包仍然存在；脚本绝不卸载或清空 `app.droidmatch`。普通
`connectedDebugAndroidTest` 的成功不能替代此 profile：设备不匹配或未显式传入
profile 时，本测试会跳过。全部 ADB 查询、安装、instrumentation 与清理命令都由进程组
超时约束。交互命令默认限时 300 秒，也可通过 `--interactive-timeout-seconds` 设置为
大于 0 且不超过 600 秒。仅新建的测试包安装若超时，不会让脚本取得清理所有权；如果测试包
已经出现，脚本会保留它、不覆盖产品包，并报告人工恢复边界。此时应等待 Android/OEM 回滚，
或另行确认所有权后再清理；重新运行时，runner 会拒绝接管预先存在的测试包。
它只是需要人工参与的定向诊断，不属于吞吐或产品 USB 插入门禁；
若没有另行定义的版本化 result-log producer/validator，也不得归档为真机证据。

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
并含精确型号 component 与精确 `ADB` component。每轮轮询只执行一次 Accessibility
观测并紧接着记录时间，短暂成功不会在同一轮被第二次观测覆盖。随后 runner 才生成新
challenge，必须
通过 controlling terminal 输入界面显示的 `INSERTED <challenge>`，明确确认真实物理插线
动作；pipe 或提前提交的输入不能生成正式证据。

正式发布还要求运行中的 App 唯一且 canonical path 等于 `--app-bundle`，bundle/签名/
entitlement 校验通过、配置为 release、内嵌 clean 完整 SHA 与运行前后两次 fresh
current-main 相等，并记录 bundle executable SHA-256，同时要求 Security.framework
读取磁盘 bundle code cdhash，并让 Security.framework 直接验证动态 guest 满足绑定
该 hash 的 requirement。只有 staged fixture 通过
`check-product-usb-insertion-logs.sh --log` 的结构与隐私校验后才可发布。Git/网络、App、TTY
或人工动作开始前，同一 checker 会枚举整个 fixture 目录，隐藏、意外、嵌套或非普通节点
一律拒绝。shell 把已渲染记录流式传给 helper 的私有无链接文件；隐私/结构验证在任一
fixture 路径创建前就完成。helper 随后固定目录并以 `O_EXCL`/`O_NOFOLLOW` 创建
`<result>.md.commit`，因此会拒绝而不是跟随或打开竞态 symlink/FIFO。helper 返回已验证
SHA-256，发布器要求完全相同的 digest，从而阻断两次 helper 调用之间换入另一份
结构合法伴随文件。发布器以非阻塞方式重开并检查路径类型，随后固定 staged 文件描述符与 inode，以不跟随
被替换节点的 no-clobber `O_EXCL`/`O_NOFOLLOW` 创建 `<result>.md`，仅从已固定、
已验证描述符复制内容，同步结果/目录后复验两个名称。两个普通文件名称成功后都持久保留
且必须逐字节一致；全目录门禁要求 result/commit 一一成对。目标已存在或竞态占用、
源替换、validator/identity 或最终复验失败都会非零退出。result 创建前或复制中中断会留下
被门禁拒绝的孤立或不一致文件对。result 创建后不会回滚；只有逐字节一致且通过证据检查的
文件对才是 commit 状态。发布与 cleanup 路径都不会 unlink 任何可能被竞态替换的证据名称。
runner 会保留状态码 3 表示发布不确定，并区分完整已验证文件对与被阻断的
孤立/不一致项；两种提示都禁止自动删除或重试，计入 fixture 前必须先检查。
受信任历史、文件名、部分型号匹配、重复卡片、fake probe、提前插线、App 缺失/不在前台、
权限缺失、确认短语错误
或超过 5 秒也都会 fail closed。自动化只能证明 App/AX 状态、时间与 artifact 身份；现场
操作者仍必须对真实断开/插入负责。两个 product USB test 脚本会离线覆盖普通文件类型与
全目录允许项、源/目标竞态、identity、持久伴随文件、孤立/不一致项、创建窗口替换、
不确定发布、Bash 3.2 空目录与普通文件矩阵，但这些测试永远不算真机证据。

### 需要人工参与的物理下载断线与续传

只在明确选定的可写测试设备上运行专用 runner，并确保 debug 产品已安装。它不会安装
APK，也不会删除调用者指定的目标文件：

```bash
tools/run-download-unplug-device-smoke.sh \
  --serial <serial> \
  --source-path dm://app-sandbox/<large-test-file> \
  --expected-bytes <精确字节数> \
  --destination /private/tmp/droidmatch-download-unplug.bin
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
上传 gate 通过或失败。结果日志先私有 staged 并校验，再以不跟随或替换既有目标的方式
发布；Git 状态不可读时 provenance 记为 unknown，而不是 clean。
每份新发布的普通日志都只携带一个 `m1-device-smoke-v1` profile；checker 会绑定其
source/build/APK provenance、slot/API、规范的 requested/passed/incomplete 检查集合、
结果/归档类别、阈值、指标、人类摘要和清理意图；传输速率按本次实传字节反算，不会把
resume 的最终 offset 当作本次字节。只有 clean、rebuilt、完整 revision 的运行属于
`device-evidence`；dirty/unknown/reused 的通过运行是 `diagnostic-only`，失败运行是
`failed-diagnostic`，两类诊断都不能满足设备门槛。89 份旧无 profile fixture 仅按
`fixtures/m1-runs/legacy-v0.sha256` 冻结的精确路径和字节摘要接受；不得编辑历史日志、
重算 manifest 或手写新的无 profile 日志。这些控制能发现矛盾或漂移记录，但不是对
物理执行的密码学证明。

当前开放的 Slot A gate 应使用版本化严格 wrapper，不要把两条松散命令手工拼成归档：

```bash
tools/run-m1-throughput-gate.sh \
  --serial <serial> \
  --expected-main-sha <40位-origin-main-SHA>
```

在任何构建或设备写入前，wrapper 会 fetch `origin/main`，并要求其完整 SHA、本地 HEAD
与人工核对后传入的 SHA 在 clean worktree 中完全一致；设备必须为 API 26–29。随后一次
fresh profile 同时验证 raw ADB baseline、双向精确 104857600 字节、请求和实际协商
1048576 字节 chunk、双向至少 20 MiB/s；计时结束后还会读取并验证受管源、已提交下载
和远端上传的 SHA-256 完全一致，因此摘要读取不会混入产品吞吐窗口。创建文件前还会预留
并验证高熵 app-sandbox source/final/partial 名称均不存在。只有 prepared source、上传 final/隐藏 partial、
本地 transfer 产物和 owned ADB forward 都确认不存在，并在结束时再次 fetch 证明
`origin/main` 未前进后，才继续发布；前后两次 Git worktree 检查命令本身也必须成功。
通用 runner 的独立 artifact 保持私有，其已验证的 `m1-device-smoke-v1` 记录会转成内嵌
producer 记录，再由 wrapper 追加唯一的 `m1-adb-throughput-v2` profile；组合后的 staged
fixture 还会绑定两份记录的完整 SHA、固定检查计划、重叠指标和固定受管 payload hash，
通过与 CI 相同的严格单日志 validator 后，才以原子 no-clobber 方式发布。只有该
pass-only v2 能满足 Slot A，吞吐 v1 继续拒绝；
离线 profile 测试使用 fake ADB/runner，不是真机证据。

在相同的 clean current-main/API 26–29 preflight 之后，wrapper 失败时可以仍以
非零退出并发布独立的 fail-only `m1-adb-throughput-diagnostic-v1`，但前提是
私有 `m1-device-smoke-v1` producer 记录已先独立通过严格 validator。组合诊断归档
内嵌该已校验 producer 记录，保留其已有指标，并只追加固定失败 stage、
source/expected/origin 绑定、
运行后 provenance、producer exit/result、managed/download/upload 摘要（未取得时为
`not-recorded`），以及聚合 remote/local/forward cleanup 与 complete/incomplete 状态。
固定 stage 只能是 `producer-exit`、`wrapper-contract`、
`download-content-integrity`、`upload-content-integrity`、`cleanup`、
`post-run-provenance`、`pass-log`、`unexpected-shell-exit` 或 `interrupted`。
该诊断永远不满足吞吐门槛；producer 无效或缺失、隐私或 validator 失败、
no-clobber 发布竞争均不生成诊断 fixture。

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

可写 SAF root 可使用类似 `dm://saf-<stable-id>/droidmatch-upload.bin` 的直接
root 单文件目标并保留相同的清理 flag。runner 会在传输结束后新建 protocol
session 调用 `delete-path`。嵌套 `dm://saf-<stable-id>/doc/<directory-token>/...`
目标会被拒绝自动清理，因为 token 仅在当前进程有效；这些目标仍需显式删除并
撤销临时 root 授权。

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
- 同一次调用中，后续 cancel/pause 探针前会重新创建临时 source，避免破坏性校验污染后续探针
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
- 同一次调用中，后续 cancel/pause 探针前会重新创建临时 source，避免破坏性校验污染后续探针
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
- 部分上传会在公开 app-sandbox root 之外创建 Android 私有不透明 staging 条目
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
  --destination /private/tmp/droidmatch-media-revoke-during-download.jpg \
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
- 日志包含权限变更、汇总 fault-proxy hook status 和恢复输出。生成的 hook 完全自包含，并丢弃私有 serial、adb 路径、命令参数及平台输出；离线测试会在全新 shell 中执行其成功与失败路径。
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

### Android endpoint 离线生命周期覆盖

`AdbEndpointAdmissionTest`、`AdbEndpointLifecycleTest` 与 `AdbEndpointLogTest`
分别覆盖 4-session 准入上限/容量释放/worker 拒绝、bind 前停止/停止后晚到 accept，
以及隐私有界的失败标签；三者共享唯一的 JVM socket/latch support seam，且不生成真机证据。

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
- ✅ Slot C MEIZU M20 在 `a897e70` 上完成 source 删除/cancel/pause/ACK 丢失组合 smoke（20/20 握手、双下载、删除返回 `notFound`、后续探针前恢复 source，以及 10MiB 上传以 27.03 MiB/s 恢复）
- ✅ Slot C MEIZU M20 在当时精确 main `aaf332a8` 上完成 Android Keystore instrumentation（`OK (2 tests)`；不可导出 identity/signing 与 AES wrapping/reopen/revoke 通过；测试包已移除且产品数据保留）
- ✅ 未归类 Pixel 9 Pro Fold API 37 双设备 ADB 路由 smoke（显式 serial 下 20/20 次尝试）
- ✅ Android 单测覆盖下载恢复时 source fingerprint 缺失、变化、不可用的拒绝路径
- ✅ `mixed-transfer-smoke` 本地 TCP 覆盖：两方向同时 open、原子下载、四块上传 refill、heartbeat、稳定源复验和不透明上传源标签
- ✅ Android 单测覆盖 invalid 和 query-mismatched page token 拒绝路径
- ✅ Mac/Android 单测覆盖 oversized envelope 拒绝路径
- ✅ Android 单测覆盖 flagged envelope-payload CRC 顺序、缺省/未知 flag，以及 mismatch 后同一会话恢复
- ✅ Mac/Android 单测覆盖 bad transfer-chunk CRC 拒绝路径
- ✅ Android 单测覆盖终止性 chunk/ACK/capability/provider 清理、四帧迟到尾包吸收、目标租约释放与 sibling/control 复用
- ❌ **阻塞：** Slot A API 26 仍缺 current-tip、release 配置下的下载/上传 ≥20 MiB/s 证据；需要经直连物理 USB 路径重跑。第二台 API 26-29 设备只是在修改协议假设或阈值前建议执行的非阻塞交叉验证
- ❌ **阻塞：** 每台已选必测 Slot A/C/D 设备都仍缺产品 USB 插入 ≤5 秒的人工归档证据
- ✅ Slot C 可写 SAF root 列表、10MiB 上传恢复与 transport-loss 恢复已归档，并清理授权与测试文件
- ✅ Slot C 2GiB app-sandbox 上传期间物理拔线、重新授权、新 forward 与跨会话恢复已归档
- ✅ Slot C 在 10GiB app-sandbox 下载期间人工物理拔线。指定 serial 在
  3626762240 字节持久 partial 后从 ADB 消失，以新 transport identity 重连，
  并以 28.35 MiB/s 恢复剩余 7110656000 字节。最终大小精确为
  10737418240 字节，原子 checkpoint 和 runner 自建 forward 均完成清理。
- ✅ Slot C `--dual-download-check` 与 `--mixed-transfer-check` 真机输出已归档
- ✅ Slot C MEIZU M20 在干净 commit `9ea1804` 上完成 current-code 回归；
  runner 的 mixed-download 目标从 macOS `/tmp` 符号链接改为规范
  `/private/tmp` 后，20/20 握手、双下载、同会话 10MiB 下载/上传与 heartbeat、
  59 ms 预热列表、下载 resume/cancel/pause 和上传 resume 均通过。修复前
  `6f00c22` 失败与通过复跑均已归档，并确认远端 final/partial、forward、
  本地临时文件及产品入口恢复。
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
