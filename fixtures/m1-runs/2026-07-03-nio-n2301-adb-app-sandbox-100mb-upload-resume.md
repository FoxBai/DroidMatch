# 2026-07-03 04:18:15Z ADB Device Smoke

status: passed
date: 2026-07-03 04:18:15Z
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK from git dc8546d
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
visible time: device already authorized over USB before script start
first list time: 920 ms for `dm://app-sandbox/`
100MB download: not run
100MB upload: partial upload plus resume passed to `dm://app-sandbox/dm-100mb-upload-resume-zero.bin`; bytes 104857600 >= required 104857600
resume result: not run
cancel result: not run
pause result: not run
permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:58e1aad1>`
- remote port: `39001`
- local port: `62368`
- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`
- m1-smoke failures: `0`
- timed list path: `dm://app-sandbox/`
- auto-prepared local 100MiB zero-file app-sandbox upload resume smoke
- upload destination: `dm://app-sandbox/dm-100mb-upload-resume-zero.bin`
- upload partial bytes: `1`
- upload destination cleanup: scheduled on script exit
- min upload bytes: `104857600`
- observed upload bytes: `104857600`

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
TotalTime: 173
WaitTime: 175
Complete
```

## Forward Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.17s)
serial=<serial-redacted:58e1aad1> local_port=62368 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.17s)
m1 smoke passed server=DroidMatchAndroid device="NIO N2301" sdk=34 battery=100 heartbeat_ms=280966116 roots=3 service_state=rpc.session.open events=8 errors=0
```

## Timed ListDir Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.17s)
list-dir passed path=dm://app-sandbox/ entries=0 next_page_token=<none>
```

## Partial Upload Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
upload partial passed bytes=1 sidecar=<upload-source>.droidmatch-upload-transfer.json
```

## Resume Upload Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
upload passed transfer_id=DFF057A2-6845-48DE-A488-8AAA90FD088F chunks=400 bytes=104857599 total=104857600 final_offset=104857600 resume=true source=<upload-source> destination=dm://app-sandbox/dm-100mb-upload-resume-zero.bin
```
