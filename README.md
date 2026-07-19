# DroidMatch

DroidMatch 是一款 macOS 原生的 Android 设备管理器。它以 USB/ADB 为当前稳定通道，由 Mac 产品 App 和 Android 安全 companion 共同完成配对、权限管理、文件浏览与可靠传输。

项目借鉴 HandShaker 中有价值的工作流，但不延续其品牌、视觉资产、二进制或代码实现。详见 [DroidMatch 与 HandShaker 的关系](docs/handshaker-relationship.md)。

> 当前处于 M1 收口期。Mac 已有可构建的 SwiftUI 产品 App 和可挂载验证的本地 DMG；Android 已有配对、连接、信任、媒体权限和 SAF 授权入口，但不是独立文件管理器。Slot C 产品认证/传输已有归档真机证据；当前真机 M1 阻塞项是 Slot A current-tip 吞吐证据与 Slot A/C/D 产品 USB 插入时延。Developer ID 签名、公证和发布自动化另行暂缓。

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
- 选择模式支持一键选择/清除当前已加载的可操作项目，并按稳定 path 多选和批量删除；分页后可继续补选，新快照会移除已消失的 stale selection，顺序执行若部分失败会强制刷新远端目录对账。
- 创建、重命名、单项删除与批量删除按实际操作映射固定的脱敏错误说明；输入弹窗内未被准入的操作会就地反馈，已准入后的远端失败才回到浏览器页面显示，不会被 sheet 遮挡或误报为“创建文件夹”失败。
- 原生文件面板或 Finder 拖放可向可写 Android 目录一次提交最多 100 个名称规范化后唯一的非符号链接普通文件；每个文件独立登记 sandbox bookmark 并进入持久上传队列，部分入队失败会明确保留并提示已接受的任务，不伪装成事务回滚。图片/视频 MediaStore root 还会在 Mac 选择、队列入场和 Android 建立 pending row 前分别校验精确媒体扩展名，未知或错分类文件不会被伪装成 JPEG/MP4。
- 选择模式可把多个可读远端文件下载到用户选择的本地目录；原生面板返回后会重新核对精确 query、row 快照、权限与队列持久化 readiness，入队前按 canonical/case/width 拒绝重名、非本地目标 URL 和已存在目标，避免陈旧面板或任何静默覆盖。每个下载任务独立持久化；若入队只部分成功，界面会明确告知已接受任务仍保留在“传输”中，并只保留未接受文件的选中状态，不会误报为整批失败或回滚。

- Mac 端 ADB 发现与转发、framed TCP/RPC、全异步会话及命令行 harness。
- 设备卡优先显示由 ADB `model/device/product` 匹配的真实商品名，并在次行保留原始技术型号；同一连接状态内也按屏幕实际显示的商品名排序，不会继续按隐藏的技术型号排列。机型映射不写在 Swift 逻辑中：少量本地审核过的厂商别名位于随 App 签名的版本化 JSON 数据表，通用加载器会限制大小/记录数并整表校验精确身份、语言标签和无凭据 HTTPS 来源。别名按 Mac 首选语言依次匹配完整语言标签、地区、文字与基础语言；没有正式别名就保留官方原名，绝不机器翻译。704SH 目前只有夏普发布的日文「シンプルスマホ4」，所以中英文系统也安全回退该原名。其他未知型号只访问固定的 Google Play 完整公开设备目录，使用无 Cookie、拒绝重定向的流式 8 MiB 上限下载和后台索引，不发送 serial 或逐设备搜索词。命中结果经安全文本投影后以完整有界参数元组的 SHA-256 键保存在本地。
- Google 目录命中的本地商品名采用 24 小时 stale-while-revalidate：未过期时完全离线；只有来源已知的过期 v3 记录会先显示安全旧值，再在后台用同一份完整目录重新核验。来源不明的旧版 v2 记录会迁移为未核验状态且在目录或当前审核别名确认前不显示；畸形 v3 条目在初始化时即从本地清除。成功核验会更新改名并移除已不再匹配的条目；下载或解析失败时只保留已核验过的安全旧值并按周期重试，不发送逐设备请求。
- 同一商品名也贯穿认证后的连接标题、“已信任设备”和诊断概览：诊断页把商品名作为主标题，并在次行保留去重后的厂商与原始型号；这只改变展示，不改变协议或存储身份。新配对会把安全限长后的商品名随原有凭据一次保存；旧配对在成功认证后只建立进程内显示覆盖，并触发无机密列表刷新，不改写或额外读取钥匙串。覆盖键仍留在 Core，Presentation 只收到名称、时间和匿名 UI ID。重启后，旧记录在再次成功连接前仍显示它原来保存的通用名。
- SwiftUI Mac 产品 target、本地 `.app` 组装脚本，以及中英文设备发现、连接、SAS 审批、分页文件浏览、独立媒体中心和隐私受限诊断界面；Files 会隐藏 Images、Image Albums、Videos 三个媒体 root，Media 是产品唯一的媒体浏览与上传入口，并在照片/相册/视频之间保留各自浏览状态，避免通用文件页绕过权限重新检查或 fresh-only 披露。未认证时各页面只提示连接并认证，不再显示“功能尚未接通”的旧占位文案。原生帮助菜单会打开本地双语连接、传输、排障和隐私指南，不再调用未打包 Help Book 的系统死入口；该帮助视图不依赖网络、设备会话或钥匙串。纯装饰 SF Symbol 以及已有文字名称的缩略图/预览不会重复进入 VoiceOver；统计卡会按“值、标签”成组，文件/媒体选择与排序公开“已选择/未选择”，图标按钮和传输方向使用本地化名称。诊断页可导出版本化 allowlist JSON 支持报告，ADB 进程与 serial 均停留在 Core 边界内。
- Android 前台连接服务、paired-required loopback ADB endpoint、配对、用户主动触发的照片/视频权限管理、SAF 授权与协议 dispatcher；debug harness 单独保留 nonce-only 证据模式。媒体区除总体“全部/受限/关闭”外，还分别显示照片和视频的实时“全部项目/已选项目/关闭”，因此单一媒体类型被拒绝时不会只留下含糊的“受限”。已配对 Mac 或 SAF 授权列表暂时不可读时，启动器不会把未知数量误报为零，并在对应 live region 内提供显式重试。配对阶段文本是只在状态变化时更新的 polite live region，视觉秒数则在独立且从无障碍树隐藏的控件中更新，因此不会每秒打断 TalkBack，也不依赖 Android 16 已弃用的主动 announcement API；等待批准时六位 SAS 逐位朗读，500 ms 轮询不会重复写入未变化的客户端名或配对码。构建基线保留 API 26 最低版本并升级到 compile/target API 36、Build Tools 36.0.0 与 SHA 固定的 Gradle 8.14.5；API 35+ launcher 会处理强制 edge-to-edge 的 system bar/cutout insets，但目前不新增 API 35/36 真机声明。
- 目录浏览，以及 App Sandbox、MediaStore、SAF 的下载和上传能力；MediaStore 图片支持带懒加载封面的 opaque 相册视图，图片/视频支持列表/自适应网格、有界缩略图和点击预览。视频根中 MIME 为 `video/*` 的正时长会在列表、网格和预览显示为 `m:ss` / `h:mm:ss`；图片、相册、SAF、App Sandbox、未知和误分类值均保持未知，这不代表视频播放或 range streaming。媒体权限仍以 Android 实时 root capability 为准：显式刷新会先清空并重列所有已加载分类，因此 Android 14 仅选媒体范围变化即使仍报告 `can_read=true` 也不会保留旧名称；权限错误停在稳定授权态等待用户重试，不会循环探测。隐藏浏览器停止派生请求发布并释放缩略图缓存，每个可见浏览器仍受 4 项活跃、64 项且 8 MiB 缓存上限约束；合法的只写 root 仍可直接提交 fresh-only 上传，界面会在操作前说明中断后必须重来。
- Mac 产品层分页目录 API 与 MainActor 浏览模型，支持 refresh/load-more、opaque token、防旧响应覆盖和跨页去重。Provider 返回的 MIME 仅作为描述性展示/图标提示：进入产品 domain 时必须是最长 127 字节的受限 ASCII 值并统一小写，畸形或超长值降级为未知，不影响条目身份、能力或授权。
- CRC32 校验、原子下载、断点续传、传输取消、检查点暂停、重试、双流调度和吞吐量测量。
- 每个下载把 final、partial、sidecar、sidecar 的 `.pending`/`.removing` 以及固定
  `.droidmatch-commit`/`.droidmatch-replaced` 视为一个命名空间；任意交集只准入
  一个非终态任务。产品执行期还按父目录 device/inode 与卷大小写语义持有进程级 reservation、
  security scope 和目录 FD，恢复出的冲突任务不会重放。
  partial 必须是单链接普通文件，并以独占 `flock` 持有到发布；fresh 只在锁定 FD 上截断。
  提交前先创建并同步 `0600` 固定 marker；替换时旧目标保留在固定 replaced entry，直到
  sidecar 已安全删除才删除旧目标、同步目录并退役 marker。sidecar 清理失败会恢复旧目标并把
  candidate 放回 partial；无法证明恢复才返回不自动重试的 `commitUncertain`。崩溃遗留任一
  recovery entry 都会把恢复任务转为 `interrupted`。这套边界要求目录 `fsync`，但不宣称
  完整断电耐久性，也不抵抗同 UID 恶意进程绕过 advisory lock。
- 可恢复上传使用 v2 强身份，把大小、纳秒 mtime/ctime、filesystem 与 inode
  绑定到整个尝试持有的单一 `O_NOFOLLOW` 源描述符；restore 尚未持有 bookmark lease 时
  只校验结构/路径，lease 建立后 coordinator 会在创建 client 前精确拒绝 stale source；
  旧非零 v1 checkpoint 会拒绝续传。
- 可选的版本化传输队列 manifest：原子写入、稳定 FIFO/任务 ID，并以 sidecar 守门跨 scheduler 重建恢复。只有结构/路径有效、total 已知无冲突且 `offset < total` 的 checkpoint 会恢复为 paused；完成、`0 / 0`、unknown/conflicting total 均为 `interrupted`。可恢复上传在首次远端 open 前双重持久化 sidecar 与精确清理身份；永久取消、失败历史移除和 shutdown 会保留可重试清理，只有新的配对认证 client 确认精确 App Sandbox/SAF private partial 已幂等删除后才 settle/移除，最终目标永不进入删除路径。sidecar/queue/bookmark 通过固定 `.pending/.removing`、完整 stat、parent 重绑定、强制文件/目录 fsync 与同进程串行锁 fail closed；无法证明回滚时报 `commitUncertain` 并保留 recovery node。
- 本地与 Slot C 真机验证过的双下载与下载/上传混合流；真机脚本已生成脱敏证据。
- `DroidMatchPresentation` 队列展示模型，以及由原生保存/批量文件选择面板提交、支持进度与暂停/继续/取消/移除的真实下载和上传队列界面。文件与媒体页的单项/批量提交共用 MainActor 单飞准入，书签、manifest 或 scheduler 登记完成前不会被另一入口重复触发；登记期间搜索、选择、行操作、导航与媒体切换也会一致禁用，批量完成只移除本次已接受的选择，不会覆盖后来状态。这不限制已登记任务按队列并发执行。队列持久化失效、正在恢复或正在批量清理时，新传输会在打开原生面板前被禁用，并就地显示可重试告警；浏览和远端文件操作仍保持可用。传输行与系统通知只接收经过 `ProductDisplayText` 净化的本地 basename，不再发布无界 basename 或未使用的完整远端逻辑路径；动作仍只按稳定 job UUID。传输页可按权威队列顺序一键清除已完全收尾的成功任务；失败、取消、interrupted 与仍在退场的任务会保留，部分清理失败显示精确计数。重试中、失败和中断行还会显示固定的可操作下一步；原因只来自 Core 精确白名单映射，任何未知或附加路径的标签都只落入无细节通用提示。
- Mac 通知设置会在打开设置页、从系统设置返回和用户主动开启时核对真实 macOS 授权；权限未授予或后来撤销时，持久开关会保持/恢复为关闭，主动拒绝还会显示固定双语说明，不再呈现一个实际无法投递的“已开启”状态。并发权限结果由 generation 拒绝旧回调；通知事件只在开关当时已开启时进入候选，真正入队前还会比较事件代次、当前开关代次与系统授权，关闭设置不会遗留一次迟到提醒，关后再开也不会复活旧候选。
- 产品传输入口和传输页的暂停、继续、取消、移除、批量清理在首次权威持久化状态读回前保持关闭，避免把初始 `.disabled` 占位值误当作已验证健康状态；恢复存储失效或正在修复时，传输页显示对应的红色/橙色状态而不是绿色成功态，竞态中被底层拒绝的行级动作会给出固定脱敏提示。这只约束传输动作，不阻止浏览或远端文件操作。
- 首次配对与重连认证的协议、密码学实现和本地测试；Android 产品入口与 Mac 生命周期会话均已接通 paired-required 模式，Slot C 真机配对/重连证据已归档。Android 的配对批准页、可信 Mac 列表、撤销确认和 SAF 授权列表只渲染 NFC 归一化、去控制/双向格式字符、折叠空白且最多 120 个 Unicode 码点的外部名称；真实截断会在上限内显示省略号，原始名称、配对身份与 SAF stable ID/tree grant 不变。Mac 的 ADB 型号/产品、配对、可信设备、ready 会话、诊断及远端文件名也统一经过有界 UI-only 安全投影（默认 120，远端条目 240 个标量），并显式标记截断；Published 配对状态仅含安全名称和六位 SAS，设备身份指纹停留在 Core。Mac 移除信任会先断开活动会话；Keychain 撤销失败会保留可信设备行并显示固定脱敏提示，超时列表的迟到快照也不能覆盖撤销结果。启动与刷新使用禁止认证 UI 的 display-only Keychain 查询；若 Security.framework 超过界面期限仍未返回，可信设备区会说明该检查不会弹窗并提示重开 App，只有旧请求真正收敛后才提供可执行的“重试”。用户主动重连时，当前记录只读取指纹匹配的配对密钥，认证成功不再为最近使用信息改写承载机密的记录；首次配对把刚写入的 Core 凭据直接用于随后的 proof，不会从钥匙串读回来。旧记录会在一个共享认证上下文中使用 macOS 兼容的逐项精确查询并一次性回填全部 selector，避免后续连接继续扫描旧记录。同一认证 generation 的传输 scheduler 直接接管刚完成证明的 Core 凭据，不再为传输创建第二次读取钥匙串；凭据不穿过 Presentation，并在接管后清除 coordinator 引用，断开或 keepalive 失败也会随会话资源释放。连接卡与本地帮助会提前说明 macOS 钥匙串提示只是授权读取设备配对密钥、不是 Apple 发行签名请求，DroidMatch 自身也没有密码输入框；本地 ad-hoc App 重建后代码身份变化仍可能令 macOS 再次询问。读取失败会先指导在系统对话框中允许后重试，不再立刻要求重新配对。

仍未完成：

- **M1 阻塞项**：SHARP 704SH（API 26）仍缺 current-tip、Swift release 配置下的 100 MiB 上传/下载 ≥20 MiB/s 证据；旧 debug/Onone 探针只是历史诊断，不能判定当前版本通过或失败。同一组三台已选必测设备还都缺产品 USB 插入到可见设备 ≤5 秒的人工归档证据。
- 704SH 紧凑屏幕的精确 v2 布局检查已有专用 runner；正式 `m1-android-launcher-layout-v1` 模式会绑定 clean current-main、全新 APK 哈希、唯一测试通过、测试包清理与 no-clobber 文件对。2026-07-19 已在精确 main `f404f7e` 上归档首份正式通过证据，覆盖首屏操作、两组等高操作行、媒体细分状态、文字适配、完整滚动和末尾“添加文件夹”控件；早期现场检查仍只算诊断。这关闭了 704SH 布局证据缺口，但不影响上述两个 M1 阻塞项的判定。
- Slot C 已归档需要人工参与的 10 GiB 下载物理 USB 拔线、同设备重连和断点续传；可写 SAF、双下载和混合流也已有 Slot C 真机证据，多 OEM SAF 扩展仍是增强项。
- 本地 ad-hoc DMG 组装与挂载校验已实现；Developer ID 签名、公证和正式发布流程按项目所有者决定延期，只有所有者再次明确提出才重启，现阶段不读取发布凭据、不向 Apple 提交产物。若以后通过网站等方式面向普通 Mac 用户分发（即使不走 Mac App Store），仍应补齐 Developer ID 与公证以通过默认 Gatekeeper；仅本机开发、自用或明确接受“仍要打开”流程的小范围受控测试不需要现在完成。AOA 仍是 M1 后探索项。

Mac 产品会话、文件浏览、结构化诊断、按认证设备隔离的持久双向传输队列和 bookmark 恢复租约已经装配；Mac 会阻止浏览 Android 当前标记为不可读的 root，同时保留合法的只写上传入口。Android 产品入口负责连接安全、照片/视频权限和 SAF 授权，不是独立的本地文件浏览器。App Sandbox bundle 已在 MEIZU M20 上归档产品配对、认证、浏览、1 MiB 双向传输，以及 `SIGKILL` 后从 App 自有 checkpoint 恢复 4 GiB 上传；本轮媒体权限 UI 尚无归档真机证据。Developer ID 签名和公证仍未完成，当前 App 不能被描述成可分发版本。

最新实现、设备证据和退出门槛以 [M1 状态总览](docs/m1-status.md) 为准；历史 fixture 只作为证据，不代替当前状态文档。
当前 GitHub 分支保护风险和分阶段治理方案见 [GitHub 仓库治理基线](docs/github-governance.md)。

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

构建包含内置 adb 的本地 sandbox release DMG，并生成 SHA-256：

```bash
tools/build-mac-dmg.sh --sandboxed
```

`.sha256` sidecar 故意记录 DMG basename，使两份文件可以成对移动而不嵌入构建机
绝对路径；因此应从产物目录执行校验。默认 0.1.0 输出示例：

```bash
cd mac/.build/dist
shasum -a 256 -c DroidMatch-0.1.0.dmg.sha256
```

App 组装脚本会在同一文件系统的私有事务中构建、验证候选 bundle；首次发布使用
`RENAME_EXCL`，替换既有 App 使用带身份复核的 `RENAME_SWAP`；
构建事务创建前与最终发布前会两次检查目标 App 是否仍有活跃进程，命中时保留旧 App 并
要求先退出；检查会同时比较当前 vnode 路径和内核保留的原启动路径，因此旧映像被
unlink、rename 或 swap 后仍能识别。检查能力不可用时发布 fail closed，最后检查后的窄竞态由产品 monitor 兜底。
已运行的旧进程无法接管替换后的可执行文件；产品会通过 `proc_pidinfo` 取得 dyld image
zero 已映射 vnode 的 device/inode 身份，再监测发布路径，避免启动到 monitor 初始化之间
的路径竞态。发现替换、移除或非普通节点后会不可逆地停止 discovery、Keychain 列表/撤销和
session 新操作，按既有顺序断开并只显示退出重开提示；进程级窗口租约会保持共享 discovery
直到最后一个活跃窗口离开。monitor 本身不读取 Keychain，也不会自动拉起另一进程。
DMG 脚本先在带 owner 的私有初始化目录写齐并同步 marker/state，再以 `RENAME_EXCL`
原子发布稳定事务；随后才在其中构建候选件，只读挂载并复核 App、签名、entitlement、
资源及 Applications 快捷方式；canonical 缺失以 `RENAME_EXCL` 发布，已有目标以
`RENAME_SWAP` 发布并双向复核，回滚按记录状态使用 EXCL/SWAP。事务以
dev/inode/size/SHA-256 绑定 previous、candidate 和 canonical 的前后身份，并对并发插入或
替换保留现场、fail closed。离线回归覆盖初始化每个落盘边界、稳定事务中的 `SIGKILL`
恢复与活跃初始化器保护；未知、伪造、不一致或不安全事务继续 fail closed。这不代表
电源故障耐久性。
验证失败会保留上一份 App 或上一对有效 DMG/checksum。
产物仍是 ad-hoc 本地验证件；Developer ID 签名和公证需要发布凭据。

发布前可运行只读预检，检查当前 commit、Developer ID/notarytool、分支保护和精确 HEAD 的托管 CI；它不会输出证书主体或凭据值：

```bash
tools/check-release-readiness.sh --github
tools/check-release-readiness.sh --github --artifact /path/to/DroidMatch.app
```

传入 App 时，预检还会验证完整代码封印、sandbox 产品边界、公证票据，以及内嵌的精确
HEAD、干净源码状态和 release 配置，并在所有慢检查结束后重新核验本地 HEAD 与工作树；
失败详情不会回显证书主体或本地路径。

仓库所有者确认一个干净、可从实时 `origin/main` 快进的候选提交后，使用下面的命令
执行无 PR 直推。它先对候选执行本地维护者契约预检，在任何远端写入前拒绝测试数量、
关键接线或接管文档漂移；随后在唯一临时 ref 上跑同一 SHA 的三项托管门禁，再次核对
main 与 Phase A 后执行非强制快进，清理临时 ref，并等待最终精确 `main push` CI。
最终快进返回失败时会先复核远端 tip，只对 main 未变化的明确网络故障做有界重试；权限、
保护规则或并发前移不会重试，每次额外写入前也会重新核验 Phase A。
Phase A 通过后还会在重试紧前再次刷新并比较远端 tip。
本地预检不替代托管门禁；这是会写入 GitHub 的维护命令，所以必须显式确认：

```bash
tools/push-main-with-gates.sh --confirm-direct-main
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

Slot A 正式吞吐证据应使用 `tools/run-m1-throughput-gate.sh`。它要求显式设备、
clean current `origin/main` 完整 SHA 和 API 26–29；在任何构建或设备写入前，它还会把
所选 ADB serial 精确映射到 macOS USB 注册表，只有不经过 Hub 的 Mac 主控直连路径才能继续。
整个底层 runner 期间会每 0.5 秒复验，结束及发布前再验；任一次缺失、重复、经过 Hub 或
无法解析都会终止且不发布失败诊断。随后一次运行锁定双向精确
100 MiB、请求/协商 1 MiB chunk、双向阈值、ADB baseline、下载/上传最终内容
SHA-256 一致性、脱敏输出和清理验证；只有内容与清理均验证完成后才发布
`m1-adb-throughput-v2` 通过日志，且只有该 pass-only profile 能满足 Slot A 吞吐门槛；
吞吐 v1 继续拒绝。
严格 preflight 之后如 wrapper 失败，只有底层 `m1-device-smoke-v1` producer
已先独立通过 validator 时，才可以非零退出并原子发布独立的
`m1-adb-throughput-diagnostic-v1` 失败诊断；它永远不算通过证据。

产品 USB 插入正式证据使用 `tools/run-product-usb-insertion-smoke.sh` 的完整模式：传入
Slot、clean current-main SHA、正在运行的 release `DroidMatch.app` 和新 fixture 路径。
runner 通过固定 AX identifier 判断产品可见性，以倒计时后的 `INSERT NOW` 为保守起点，
并只在 App artifact provenance、≤5 秒时延、人工物理动作确认和专用日志校验都通过后发布。

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
