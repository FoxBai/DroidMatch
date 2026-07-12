# 2026-07-11 20:00:05Z ADB Large Directory Memory Diagnostic

status: passed
date: 2026-07-11 20:00:05Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local debug APK and working tree based on git b59e3b1
transport: ADB dynamic forward to debug harness Activity endpoint
handshake attempts: one debug-harness handshake passed
visible time: device already authorized over USB before probe start
first list time: diagnostic-only 968 ms for all 1,005 app-sandbox entries
100MB download: not run
100MB upload: not run
resume result: not run
permission cases: not run; app-private run-as seed only
diagnostics bundle: aggregate process PSS sampled through Android dumpsys
notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- command shape: `list-dir-all --page-size 1000 --expected-total 1005`
- aggregate result: `pages=2 page_counts=1000,5 entries=1005 elapsed_ms=968`
- memory result: `baseline_pss_kib=31664 peak_pss_kib=38313 delta_pss_kib=6649`
- interpretation boundary: this is an observed process-level PSS sample, not a heap-allocation proof or a cross-device memory limit
- timing boundary: concurrent `dumpsys meminfo` sampling perturbs the request, so 968 ms is not used as a latency gate
- privacy boundary: the runner emitted only a validated aggregate result shape; no entry name, logical path, absolute path, opaque cursor, or raw serial was archived
- cleanup verification: the runner verified absence of its exact generated directory and forward before reporting success
