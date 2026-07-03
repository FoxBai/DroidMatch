# 2026-07-03 03:55:29Z ADB Device Smoke

status: passed
date: 2026-07-03 03:55:29Z
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK from git a0edd20
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
visible time: device already authorized over USB before script start
first list time: 943 ms for `dm://app-sandbox/`
100MB download: not run
100MB upload: `upload` command passed to `dm://app-sandbox/dm-1mb-upload-zero.bin`; bytes 1048576 >= required 1048576
resume result: not run
cancel result: not run
pause result: not run
permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:58e1aad1>`
- remote port: `39001`
- local port: `60599`
- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`
- m1-smoke failures: `0`
- timed list path: `dm://app-sandbox/`
- auto-prepared local 1MiB zero-file app-sandbox upload smoke
- upload destination: `dm://app-sandbox/dm-1mb-upload-zero.bin`
- upload destination cleanup: scheduled on script exit
- min upload bytes: `1048576`
- observed upload bytes: `1048576`

## Install Output

```text
Performing Streamed Install
Success
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
TotalTime: 182
WaitTime: 185
Complete
```

## Forward Output

```text
[0/1] Planning build
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (1.75s)
serial=<serial-redacted:58e1aad1> local_port=60599 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
m1 smoke passed server=DroidMatchAndroid device="NIO N2301" sdk=34 battery=100 heartbeat_ms=279601391 roots=3 service_state=rpc.session.open events=8 errors=0
```

## Timed ListDir Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
list-dir passed path=dm://app-sandbox/ entries=0 next_page_token=<none>
```

## Upload Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
upload passed transfer_id=A66FAFC2-7AC5-423C-93C8-CCFA36B9DD18 chunks=4 bytes=1048576 total=1048576 final_offset=1048576 source=<upload-source> destination=dm://app-sandbox/dm-1mb-upload-zero.bin
```
