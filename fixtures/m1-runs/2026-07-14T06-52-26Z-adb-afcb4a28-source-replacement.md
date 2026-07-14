# 2026-07-14 06:53:07Z ADB Device Smoke

status: passed
date: 2026-07-14 06:53:07Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local release Swift harness + debug APK from git 0b4d858
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
dual-stream download: not run
mixed-stream transfer: not run
visible time: device already authorized over USB before script start
first list time: 58 ms for `<dm-path-redacted>`
adb baseline download: not run
100MB download: source-replacement check used a script-created source; partial download completed for `<dm-path-redacted>`, a same-size/same-mtime atomic replacement changed inode/content, and resume correctly rejected the changed fingerprint; 100MB size not asserted
100MB upload: not run
resume result: partial stop after at least 262144 byte(s), then same-size/same-mtime atomic source replacement was rejected with stable code `invalidArgument` (fingerprint detail redacted)
cancel result: not run
pause result: not run
permission cases: launcher entry resolved to `DroidMatchActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- remote port: `39001`
- local port: `60510`
- launcher: `app.droidmatch/app.droidmatch.m1.DroidMatchActivity`
- m1-smoke failures: `0`
- timed list path: `<dm-path-redacted>`
- timed list command wall time: `840 ms`
- prepared app sandbox file: `<name-redacted>`
- prepared app sandbox bytes: `1048576`
- prepared app sandbox cleanup: scheduled on script exit
- download source replacement check: same-directory rename preserved size/mtime, changed inode/content, and required stable `invalidArgument` on resume; raw metadata and fingerprint detail remain omitted
- download source destructive-check cleanup: recreated the script-created app-sandbox source before subsequent cancel/pause probes

## Install Output

```text
Performing Streamed Install
Success
```

## Prepare App Sandbox Output

```text
mkdir:

dd:
1+0 records in
1+0 records out
1048576 bytes (1.0 M) copied, 0.001 s, 0.9 G/s
verify:
-rw-rw-rw- 1 u0_a191 u0_a191 1048576 2026-07-14 14:53 files/droidmatch-sandbox/<name-redacted>
```

## Launcher Resolve Output

```text
priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false
app.droidmatch/.m1.DroidMatchActivity
```

## Activity Start Output

```text
Starting: Intent { cmp=app.droidmatch/.m1.DebugHarnessActivity (has extras) }
Status: ok
LaunchState: COLD
Activity: app.droidmatch/.m1.DebugHarnessActivity
TotalTime: 442
WaitTime: 445
Complete
```

## Forward Output

```text
[0/1] Planning build
Building for production...
[0/2] Write swift-version--1AB21518FC5DEDBE.txt
Build of product 'droidmatch-harness' complete! (1.98s)
serial=<serial-redacted:afcb4a28> local_port=60510 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for production...
[0/2] Write swift-version--1AB21518FC5DEDBE.txt
Build of product 'droidmatch-harness' complete! (0.16s)
m1 smoke passed server=DroidMatchAndroid device="meizu MEIZU M20" sdk=34 battery=100 heartbeat_ms=3164116462 roots=4 service_state=adb.endpoint.accepted events=9 errors=0
```

## Timed ListDir Output

```text
Building for production...
[0/2] Write swift-version--1AB21518FC5DEDBE.txt
Build of product 'droidmatch-harness' complete! (0.16s)
list-dir passed path=<path-redacted> entries=2 next_page_token=<none> elapsed_ms=58
entries redacted: 2
```

## Partial Download Output

```text
Building for production...
[0/2] Write swift-version--1AB21518FC5DEDBE.txt
Build of product 'droidmatch-harness' complete! (0.15s)
download partial passed bytes=262144 partial=<local-partial> sidecar=<local-sidecar>
```

## Download Source Replacement Output

```text
replacement: same-directory atomic rename after partial download
size_preserved=true mtime_preserved=true inode_changed=true content_changed=true
replacement seed: completed (1048576 bytes)
```

## Download Source Restore Output

```text
source: <dm-path-redacted>
restore: recreated disposable source before subsequent probes
bytes: 1048576
adb dd output:
1+0 records in
1+0 records out
1048576 bytes (1.0 M) copied, 0.001 s, 0.9 G/s
adb verification output:
-rw-rw-rw- 1 u0_a191 u0_a191 1048576 2026-07-14 14:53 files/droidmatch-sandbox/<name-redacted>
```

## Resume Download Output

```text
Building for production...
[0/2] Write swift-version--1AB21518FC5DEDBE.txt
Build of product 'droidmatch-harness' complete! (0.16s)
download failed: remote error: invalidArgument
```
