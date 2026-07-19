# Android launcher layout evidence

This directory is reserved for attended `m1-android-launcher-layout-v1`
fixtures produced by `tools/run-704sh-layout-instrumentation.sh`. Formal runs
must use clean current `origin/main`, rebuild both debug APKs from scratch,
execute the exact `slot-a-704sh-layout-v2` profile on SHARP 704SH / API 26, and
prove that the test package was absent before the run, removed afterward, and
that the pre-existing product package remained installed without uninstall or
data clearing.

The fixture contains only fixed profile facts, full source/APK hashes, and
privacy-bounded pass/cleanup state. It never contains the ADB serial, local
paths, raw instrumentation output, user data, filenames, content URIs, or
credentials. A passing record means exactly one instrumentation test exercised
the fixed 720x1280 display, 720x1136 app viewport, 320 dpi, en-US locale, 1.3
font scale, initial action bounds, equal-height action rows, populated media
detail rows, unclipped visible button text, full-page scrolling, and the final
control above system navigation. It does not prove throughput, USB insertion
latency, TalkBack output, Developer ID signing, or notarization.

Only this regular `README.md` and byte-identical regular-file
`<name>.md`/`<name>.md.commit` pairs are allowed. The runner validates the
record privately before no-clobber publication. Failed, skipped, timed-out,
dirty, stale, reused-APK, cleanup-uncertain, or manually copied output must not
be placed here.

中文：本目录只保存人工执行的 `m1-android-launcher-layout-v1` 启动器布局证据。
正式运行必须使用 clean current `origin/main`，从头构建两份 debug APK，在 SHARP
704SH / API 26 上执行精确 `slot-a-704sh-layout-v2`，并确认测试包运行前不存在、
运行后已清理，原有产品包始终保留且从未卸载或清空数据。fixture 只记录固定 profile
事实、完整源码/APK 哈希和脱敏后的通过/清理状态；不得包含 ADB serial、本地路径、
原始 instrumentation 输出、用户数据、文件名、content URI 或凭据。失败、跳过、超时、
dirty、旧源码、复用 APK、清理不确定或手工复制的输出都不能进入本目录。
