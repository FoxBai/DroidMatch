# 2026-07-03 02:39:50Z ADB Device Smoke

status: passed
date: 2026-07-03 02:39:50Z
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK from git 1658552
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
visible time: device already authorized over USB before script start
first list time: 1009 ms for `dm://media-images/`
100MB download: cancel-check passed for `dm://media-images/media/1000001370`; 100MB size not asserted
100MB upload: not implemented
resume result: not run
cancel result: `download-cancel` passed after the first chunk for `dm://media-images/media/1000001370`
permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:58e1aad1>`
- remote port: `39001`
- local port: `56548`
- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`
- m1-smoke failures: `0`
- timed list path: `dm://media-images/`
- download-cancel smoke after first chunk; 100MB size not asserted

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
TotalTime: 189
WaitTime: 192
Complete
```

## Forward Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.19s)
serial=<serial-redacted:58e1aad1> local_port=56548 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
m1 smoke passed server=DroidMatchAndroid device="NIO N2301" sdk=34 battery=96 heartbeat_ms=275060489 roots=3 service_state=rpc.session.open events=8 errors=0
```

## Timed ListDir Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
list-dir passed path=dm://media-images/ entries=48 next_page_token=<none>
entries redacted: 48
```

## Cancel Download Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.19s)
download-cancel passed transfer_id=8A635B9C-DE1C-4C9A-A435-05B21EA0E29D first_chunk_bytes=127695 total=127695 cancel_ok=true
```
