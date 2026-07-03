# 2026-07-03 02:53:07Z ADB Device Smoke

status: passed
date: 2026-07-03 02:53:07Z
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK from git dd642b8-dirty
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
visible time: device already authorized over USB before script start
first list time: 991 ms for `dm://app-sandbox/`
100MB download: partial download plus resume passed for `dm://app-sandbox/dm-100mb-zero.bin`; bytes 104857600 >= required 104857600
100MB upload: not implemented
resume result: partial stop after at least 1 byte(s), then `download --resume` passed
cancel result: not run
permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:58e1aad1>`
- remote port: `39001`
- local port: `57396`
- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`
- m1-smoke failures: `0`
- timed list path: `dm://app-sandbox/`
- app-sandbox 100MiB zero-file download with resume; generated under app private files/droidmatch-sandbox
- min download bytes: `104857600`
- observed download bytes: `104857600`
- local destination size verified: `104857600` bytes
- local destination SHA-256: `20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e`

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
TotalTime: 190
WaitTime: 194
Complete
```

## Forward Output

```text
[0/1] Planning build
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (1.81s)
serial=<serial-redacted:58e1aad1> local_port=57396 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
m1 smoke passed server=DroidMatchAndroid device="NIO N2301" sdk=34 battery=99 heartbeat_ms=275859725 roots=3 service_state=rpc.session.open events=8 errors=0
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
download passed transfer_id=2CFA847F-C1B3-457C-B350-2531B46BF969 chunks=399 bytes=104595456 total=104857600 final_offset=104857600 resume=true destination=<download-destination>
```
