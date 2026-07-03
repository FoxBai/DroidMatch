# 2026-07-03 17:40:44Z ADB Device Smoke

status: passed
date: 2026-07-03 17:40:44Z
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK from git 03ff2ec-dirty
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
visible time: device already authorized over USB before script start
first list time: not measured by this script
100MB download: not run
100MB upload: fresh-only resume unsupported check and `upload` passed to `dm://media-images/droidmatch-probe-log-1783100444.jpg`; bytes 45 >= required 45
resume result: not run
cancel result: not run
pause result: not run
permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:58e1aad1>`
- remote port: `39001`
- local port: `54416`
- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`
- m1-smoke failures: `0`
- MediaStore upload open with non-zero offset rejected before fresh upload; destination cleaned after run.
- upload destination: `dm://media-images/droidmatch-probe-log-1783100444.jpg`
- upload resume unsupported check: requested offset `1`, expected `unsupportedCapability`
- upload destination cleanup: scheduled on script exit
- min upload bytes: `45`
- observed upload bytes: `45`

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
Build of product 'droidmatch-harness' complete! (0.22s)
serial=<serial-redacted:58e1aad1> local_port=54416 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.19s)
m1 smoke passed server=DroidMatchAndroid device="NIO N2301" sdk=34 battery=59 heartbeat_ms=288995121 roots=3 service_state=rpc.session.open events=8 errors=0
```

## Upload Resume Unsupported Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.19s)
upload open error passed code=unsupportedCapability requested_offset=1 destination=dm://media-images/droidmatch-probe-log-1783100444.jpg message="MediaStore upload resume is not supported"
```

## Upload Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.20s)
upload passed transfer_id=FBF1504F-B329-4A97-8235-5A2A620E1E00 chunks=1 bytes=45 total=45 final_offset=45 resume=false source=<upload-source> destination=dm://media-images/droidmatch-probe-log-1783100444.jpg
```
