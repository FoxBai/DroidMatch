# 2026-07-03 03:01:36Z ADB Device Smoke

status: passed
date: 2026-07-03 03:01:36Z
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK from git f5fccd3
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
visible time: device already authorized over USB before script start
first list time: 993 ms for `dm://app-sandbox/`
100MB download: partial download plus resume passed for `dm://app-sandbox/dm-100mb-auto-zero.bin`; bytes 104857600 >= required 104857600
100MB upload: not implemented
resume result: partial stop after at least 1 byte(s), then `download --resume` passed
cancel result: not run
permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:58e1aad1>`
- remote port: `39001`
- local port: `57982`
- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`
- m1-smoke failures: `0`
- timed list path: `dm://app-sandbox/`
- auto-prepared app-sandbox 100MiB zero-file download with resume
- prepared app sandbox file: `dm-100mb-auto-zero.bin`
- prepared app sandbox bytes: `104857600`
- prepared app sandbox cleanup: scheduled on script exit
- min download bytes: `104857600`
- observed download bytes: `104857600`
- local destination size verified: `104857600` bytes
- local destination SHA-256: `20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e`

## Install Output

```text
Performing Streamed Install
Success
```

## Prepare App Sandbox Output

```text
mkdir:

dd:
100+0 records in
100+0 records out
104857600 bytes (100 M) copied, 0.030 s, 3.2 G/s
verify:
-rw-rw-rw- 1 u0_a220 u0_a220 104857600 2026-07-03 11:01 files/droidmatch-sandbox/dm-100mb-auto-zero.bin
```

## Launcher Resolve Output

```text
priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false
app.droidmatch/.m1.DiagnosticsActivity
```

## Activity Start Output

```text
Starting: Intent { cmp=app.droidmatch/.m1.DebugHarnessActivity (has extras) }
Status: ok
LaunchState: COLD
Activity: app.droidmatch/.m1.DebugHarnessActivity
TotalTime: 188
WaitTime: 190
Complete
```

## Forward Output

```text
[0/1] Planning build
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (1.80s)
serial=<serial-redacted:58e1aad1> local_port=57982 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
m1 smoke passed server=DroidMatchAndroid device="NIO N2301" sdk=34 battery=100 heartbeat_ms=276368969 roots=3 service_state=rpc.session.open events=8 errors=0
```

## Timed ListDir Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
list-dir passed path=dm://app-sandbox/ entries=1 next_page_token=<none>
entries redacted: 1
```

## Partial Download Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
download partial passed bytes=262144 partial=<download-destination>.droidmatch-part sidecar=<download-destination>.droidmatch-transfer.json
```

## Resume Download Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
download passed transfer_id=589D4FCD-1082-4A0B-AB9A-99E96DC6AAA9 chunks=399 bytes=104595456 total=104857600 final_offset=104857600 resume=true destination=<download-destination>
```
