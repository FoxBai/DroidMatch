# 2026-07-12 MEIZU Large Directory Memory Diagnostic

status: passed
date: 2026-07-12 22:33Z terminal-captured run; archived at 22:37:26Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local debug APK and working tree based on git 6b1c429
transport: ADB dynamic forward to debug harness Activity endpoint
handshake attempts: one debug-harness handshake passed
visible time: device already authorized over USB before probe start
first list time: diagnostic-only 1004 ms for all 1,005 app-sandbox entries
100MB download: not run
100MB upload: not run
resume result: not run
permission cases: not run; app-private run-as seed only
diagnostics bundle: aggregate process PSS sampled through Android dumpsys
notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- command shape: `list-dir-all --page-size 1000 --expected-total 1005`
- aggregate result: `pages=2 page_counts=1000,5 entries=1005 elapsed_ms=1004`
- memory result: `baseline_pss_kib=31228 peak_pss_kib=38482 delta_pss_kib=7254`
- interpretation boundary: this is an observed process-level PSS sample, not a heap-allocation proof or a cross-device memory limit
- timing boundary: concurrent `dumpsys meminfo` sampling perturbs the request, so 1004 ms is not used as a latency gate
- privacy boundary: only aggregate values were emitted; no entry name, logical path, absolute path, cursor, or raw serial was archived
- cleanup verification: the runner reported `cleanup=verified` after confirming absence of its exact generated directory and forward
