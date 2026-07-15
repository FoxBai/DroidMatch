# Product USB insertion evidence

This directory is reserved for attended `m1-product-usb-insertion-v1` fixtures
created by `tools/run-product-usb-insertion-smoke.sh`. A formal run must use the
current clean `origin/main`, exactly one foreground release product App at the
caller-specified canonical path whose embedded full source revision matches that
commit, the fixed three-second arming countdown, the monotonic timestamp taken
before the explicit `INSERT NOW` signal, and the stable discovery-card
Accessibility identifier. The fixture records the bundle executable SHA-256,
an on-disk code cdhash plus dynamic-guest requirement verification, the bundle
variant and verification result, and post-run physical-action attestation.

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

Do not copy offline fake-probe output into this directory. Never add raw ADB
serials, personal paths, content URIs, credentials, or unrelated UI text.

中文：本目录只保存人工执行的 `m1-product-usb-insertion-v1` 证据。正式运行必须使用
clean current-main、内嵌完整匹配 SHA 的前台产品 App、固定三秒布防倒计时、明确的
`INSERT NOW` 起点和稳定的发现卡片 Accessibility 标识。fake probe 输出不是真机证据，
不得复制到这里，也不得加入原始 serial、个人路径、content URI 或凭据。staged 与最终
fixture 都必须是普通、非 symlink 文件；人工流程前 checker 会枚举整个目录，只允许本
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
