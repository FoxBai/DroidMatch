# 2026-07-01 NIO N2301 ADB Stream Reader Regression

date: 2026-07-01
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed
visible time: device already authorized over USB
first list time: not measured
100MB download: not run
100MB upload: not implemented
resume result: not exercised on device in this run
permission cases: existing media image permission available
diagnostics bundle: `m1-smoke` returned diagnostics errors=0
notes:

- This run verified the Android provider stream-reader change that keeps one provider stream open across ACK-driven download chunks.
- Started `DebugHarnessActivity` with `--ei port 39501`, then forwarded local port `52086`.
- `m1-smoke` passed: server `DroidMatchAndroid`, device `NIO N2301`, SDK `34`, battery `92`, roots `3`, diagnostics errors `0`.
- `download --source-path dm://media-images/media/1000001370 --chunk-size 65536` downloaded 127695 bytes in 2 chunks to `/tmp/droidmatch-nio-screenshot.jpg`.
- Download SHA-256: `cfe0b2d7905f83bf83872126b262575604ff77753851a8e0925adb291bf7a0e0`.
