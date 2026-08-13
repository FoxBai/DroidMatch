# Product USB insertion evidence

This directory is reserved for attended `m1-product-usb-insertion-v2` fixtures
created by `tools/run-product-usb-insertion-smoke.sh`. A formal run must use the
current clean `origin/main`, exactly one foreground sandbox-entitled release product App at the
caller-specified canonical path whose embedded full source revision matches that
commit, the fixed three-second arming countdown, the monotonic timestamp taken
before the explicit `INSERT NOW` signal, and the stable discovery-card
Accessibility identifier. The fixture records the bundle executable SHA-256,
an on-disk code cdhash plus dynamic-guest requirement verification, the bundle
variant and verification result, and post-run physical-action attestation. The
formal label is derived from the frozen `m1-product-usb-selected-devices-v1`
registry at `tools/product-usb-selected-devices-v1.json` rather than operator
input. Replacing a selected device requires a new registry/profile version;
this mapping must not be rewritten in place. Private, bounded ADB snapshots require the
reviewed serial to be absent before arming and immediately before the signal,
then prove it is the only new ready device; its reviewed 128-bit pseudonymous tag,
manufacturer, model, and API must match the selected Slot A/C/D profile. Raw ADB
serials and private snapshots are never written here.
Inside the temporary workspace, every inventory serial is represented only by a
non-raw HMAC pseudonym keyed by the selected device; normal publication removes
those snapshots before creating the fixture.
Formal filenames contain only the UTC timestamp, slot, and reviewed 32-hex
tag; raw serials are rejected from repository paths as well as file contents.
Formal v2 accepts only an `--evidence-ready` clean-system build and uses only the
App's sealed embedded adb. The bundle records that build mode; candidate verification
binds the signed ADB's static bytes and CodeDirectory identity, while final verification
also executes its version/build check before the runner accepts it.
A reviewed registry records its signed bytes,
build/version, and dedicated `tcp:localhost:47137` socket in
`tools/product-usb-adb-v1.json`; replacing platform-tools requires a new registry
and evidence-profile version. Core selects that bundled executable ahead of
development overrides. In a sandbox process it is an exclusive choice: a missing
or unusable embedded file fails discovery instead of falling back to an SDK/HOME/PATH
client or default server. It executes it directly with only sandbox HOME/TMPDIR, and
uses the dedicated socket. The runner rejects server overrides, pins reviewed bytes
into a single-link `0700` private client copy, and invokes that copy on the same
socket with a private empty HOME/TMPDIR and numeric-loopback remote-client
arguments. Loss of the reviewed server is refused rather than auto-starting a
daemon from the temporary copy. It repeatedly verifies that the unique listener
belongs to the current effective user, plus its boot-scoped start identity,
`proc_pidpath`, mapped executable device/inode from
`lsof`, and live `csops` CodeDirectory hash with valid hardened-runtime and
non-debugged flags. Another executable,
listener, or server process instance cannot publish evidence.
This profile does not attest daemon parentage or inherited server environment.
Orderly server shutdown remains separate product-lifecycle hardening and is not
part of the five-second measurement.
The reviewed 128-bit tag and property checks are pseudonymous ADB-profile binding,
not Android hardware cryptographic attestation. A malicious or rooted device that
can spoof the reviewed serial and properties is outside this M1 evidence boundary;
the operator attestation remains the physical-action proof.
The profile assumes no malicious same-UID process actively races the private
workspace, executable pathname, or publisher. Its clean environment, pinned Git
tree bytes, and repeated file/process/code checks address accidental drift, not
isolation from a hostile process running as the same user.

The runner may publish here only after the selected device is absent both before
arming and immediately before the insertion signal, becomes product-visible in
at most 5000 ms, the repository still matches freshly fetched `origin/main`, and
the staged log passes `tools/check-product-usb-insertion-logs.sh --log`. Both the
staged record and final fixture must be regular, non-symlink files. Before the
attended run, the checker enumerates this entire directory; only this regular
`README.md` and one-to-one byte-identical `<name>.md`/`<name>.md.commit`
regular-file pairs are allowed. The shell streams the record to the helper, which
first validates privacy/schema in a private unlinked file, before either fixture
pathname exists. It then pins the directory and creates the commit companion with
`O_EXCL`/`O_NOFOLLOW`; a raced symlink or FIFO is rejected rather than followed or
opened. The helper returns the validated SHA-256 and publication requires the same
digest, binding the handoff against a schema-valid companion replacement.
Publication reopens entries nonblocking, type-checks them, pins the companion
descriptor and inode, and opens the result with no-clobber
`O_EXCL`/`O_NOFOLLOW`, copies only from the pinned descriptor, syncs the result
and directory, and revalidates both names. Both names persist after success.
Existing or racing targets, source replacement, validator/identity failures, and
final revalidation failures return non-zero. An interruption before or during
result creation leaves an orphan or mismatch rejected by the directory gate. A
created result is never rolled back; only a byte-identical pair that passes the
evidence checks is a commit state. Publication and cleanup never unlink either
evidence pathname.
The runner preserves uncertain publication as exit status 3, reports whether a
complete validated pair or a blocked orphan/mismatch remains, and forbids
automatic deletion or retry until the fixture has been inspected.

Directory validation accepts partial historical slot archives across current-main
revisions and rejects a reviewed identity reused across slots. Only
`tools/check-product-usb-insertion-logs.sh --require-complete-matrix` proves that
one source revision contains all required Slots A/C/D; the covered-slot union and
partial or cross-revision evidence never close the M1 gate.
Use separate clean worktrees or clones at that same revision for later slots,
because publishing the first fixture dirties its producing checkout.

Do not copy offline fake-probe output into this directory. Never add raw ADB
serials, personal paths, content URIs, credentials, or unrelated UI text.

中文：本目录只保存人工执行的 `m1-product-usb-insertion-v2` 证据。正式运行必须使用
clean current-main、内嵌完整匹配 SHA 的前台 sandbox 产品 App、固定三秒布防倒计时、明确的
`INSERT NOW` 起点和稳定的发现卡片 Accessibility 标识。正式标签来自冻结的
`m1-product-usb-selected-devices-v1` 清单，而不是操作者输入；私有、有界 ADB 快照要求
所选 serial 在布防前与信号前均不存在，随后证明它是唯一新增的 ready 设备，并让既有
128 位假名标签、厂商、型号与 API 精确匹配 A/C/D 槽位。原始 serial 与私有快照不会写入
本目录。临时工作区内的库存 serial 也只表示为以所选设备为键的非原始 HMAC 假名，正常
发布会在创建 fixture 前删除这些快照。fake probe 输出不是真机证据，
不得复制到这里，也不得加入原始 serial、个人路径、content URI 或凭据。
正式 v2 只接受 `--evidence-ready` 干净系统构建，并只使用 App resource seal 中的内嵌
adb；bundle 会记录该构建模式。候选 verifier 绑定签名后 ADB 的静态字节与 CodeDirectory
身份，最终 verifier 再执行 version/build 检查，全部通过后 runner 才会接受。`tools/product-usb-adb-v1.json`
以受审查清单记录其签名后字节、版本、build 与专用 `tcp:localhost:47137` socket；更换 platform-tools
必须新增清单与证据 profile 版本。sandbox Core 排他选择并直接执行它；缺失或不可执行时
会拒绝发现，不会回退 SDK/HOME/PATH client 或默认 server。只传入 sandbox HOME/TMPDIR；runner 拒绝 server 覆盖，把受审查字节固定到单链接
`0700` 私有 client 副本，并通过同一 socket、私有空 HOME/TMPDIR 与数值 loopback 远端连接
参数执行；受审查 server 消失时会拒绝，而不会从私有副本自动启动 daemon。runner 同时重复核对唯一
loopback listener 属于当前有效用户，以及它的本次开机启动身份、`proc_pidpath`、`lsof` 映射可执行文件的 device/inode，
以及 live `csops` CodeDirectory hash、有效 hardened-runtime 且非 debug 状态。另一
可执行文件、listener 或 server 进程实例不能发布证据。
本 profile 不证明 daemon 父进程或继承环境；正常退出时回收 server 仍属于独立的产品
生命周期加固，不计入五秒测量。
受审查的 128 位标签与属性核对属于 ADB profile 的假名绑定，不是 Android 硬件级密码学
证明；能伪造该 serial 与属性的恶意或 rooted 设备不在本 M1 证据边界内，物理动作仍由
操作者确认来证明。
本 profile 假设同一 UID 下没有恶意进程主动竞态替换私有工作区、可执行路径或 publisher；
干净环境、固定 Git tree 字节和反复文件/进程/代码复核用于阻断意外漂移，不构成对 hostile
same-UID 进程的隔离。
staged 与最终 fixture 都必须是普通、非 symlink 文件；人工流程前 checker 会枚举整个目录，只允许本
README 普通文件与一一对应、逐字节相同的 `<name>.md`/`<name>.md.commit`
普通文件对。shell 把记录流式传给 helper；helper 先在私有无链接文件中完成隐私/结构验证，
之后才固定目录并以 `O_EXCL`/`O_NOFOLLOW` 创建 commit 伴随文件，因此会拒绝而不是跟随或
打开竞态 symlink/FIFO。helper 返回已验证 SHA-256，发布器要求同一 digest，从而阻断两次调用之间
换入另一份结构合法伴随文件。发布器以非阻塞方式重开并检查节点类型，固定伴随文件描述符与
inode，以 no-clobber
`O_EXCL`/`O_NOFOLLOW` 创建
result，仅从已固定描述符复制，同步结果/目录并复验两个名称。成功后两者都持久保留。
既有/竞态目标、源替换、validator/identity 或最终复验失败都会非零退出。result 创建前或复制中
中断会留下被全目录门禁拒绝的孤立或不一致文件对。result 创建后不会回滚；只有逐字节一致
且通过证据检查的文件对才是 commit 状态。发布与 cleanup 绝不 unlink 两个证据路径。
runner 保留状态码 3 表示不确定发布，会说明完整已验证文件对或被阻断的孤立/
不一致项哪一种仍存在，并在检查前禁止自动删除或重试。
全目录普通校验允许跨不同 current-main 版本逐槽累积历史部分证据，并拒绝跨槽复用同一受审查身份；只有显式
`--require-complete-matrix` 找到同一源码版本的 A/C/D 全部覆盖，才能关闭门禁。历史 covered-slots
并集、部分证据或跨版本拼接都不能关闭 M1 门禁。
首份 fixture 发布后其 checkout 会变脏，因此后续槽位应从同一 revision 的独立 clean
worktree 或 clone 采集。
