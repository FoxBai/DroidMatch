# 2026-07-11 13:31:00Z ADB Large Directory Smoke

status: passed
date: 2026-07-11 13:31:00Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local debug APK and working tree based on git 5ebb2b7
transport: ADB dynamic forward to debug harness Activity endpoint
handshake attempts: one debug-harness handshake passed
visible time: device already authorized over USB before probe start
first list time: 833 ms for all 1,005 app-sandbox entries
100MB download: not run
100MB upload: not run
resume result: not run
permission cases: not run; app-private run-as seed only
diagnostics bundle: not run
notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- command: `list-dir-all --page-size 1000 --expected-total 1005`
- aggregate result: `pages=2 page_counts=1000,5 entries=1005 elapsed_ms=833`
- seed verification: exactly 1,005 empty files before the protocol probe
- privacy boundary: no entry name, logical path, absolute path, or opaque cursor was printed
- cleanup verification: the generated app-sandbox directory was absent after the EXIT trap
- forward cleanup: the probe forward and stale forwards to the debug endpoint were removed
