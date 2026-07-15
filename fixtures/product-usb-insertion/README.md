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
staged record and final fixture must be regular, non-symlink files. Publication is
a no-clobber `ln -n` hard-link commit and is not successful until the staged link
has been removed. Existing or racing regular files, dangling or directory symlinks,
validator/link failures, and staging-unlink failures all return non-zero without
replacing a competing result path.

Do not copy offline fake-probe output into this directory. Never add raw ADB
serials, personal paths, content URIs, credentials, or unrelated UI text.

中文：本目录只保存人工执行的 `m1-product-usb-insertion-v1` 证据。正式运行必须使用
clean current-main、内嵌完整匹配 SHA 的前台产品 App、固定三秒布防倒计时、明确的
`INSERT NOW` 起点和稳定的发现卡片 Accessibility 标识。fake probe 输出不是真机证据，
不得复制到这里，也不得加入原始 serial、个人路径、content URI 或凭据。staged 与最终
fixture 都必须是普通、非 symlink 文件；runner 用 no-clobber `ln -n` hard link 发布，
且仅在 staged link 删除后报告成功。既有/竞态文件、dangling/目录 symlink、validator/link
失败或 staging unlink 失败都会非零退出，并保留竞争者结果路径不动。
