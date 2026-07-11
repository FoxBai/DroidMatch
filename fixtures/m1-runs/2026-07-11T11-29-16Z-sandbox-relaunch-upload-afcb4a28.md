# 2026-07-11 11:29:16Z Sandboxed Product Relaunch Upload Recovery

status: passed
date: 2026-07-11 11:29:16Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local ad-hoc-signed sandbox release Mac App from git 846034f; local debug Android APK
transport: paired-required ADB forward through the product launchers
handshake attempts: 2/2 passed (pre-crash authenticated session and post-relaunch reconnect)
visible time: device already authorized over USB before the run
first list time: not separately timed; authenticated app-sandbox listing passed before upload
100MB download: not run
100MB upload: passed with a disposable sparse 4GiB source and forced App termination
resume result: passed after product relaunch from a durable App-owned checkpoint
permission cases: the reopened queue reacquired the persisted single-file security-scoped bookmark
diagnostics bundle: not exported

notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- the sandbox product authenticated through its existing non-synchronizing Keychain record
- the native file panel selected one disposable 4GiB source in a normal user-authorized directory
- after the Android partial reached 598,999,040 bytes, the App-owned upload checkpoint and device-isolated queue manifest were both present; the Mac product process was then terminated with `SIGKILL`
- relaunch restored the active job as paused instead of replaying it automatically; the user-visible Resume control started attempt 2
- attempt 2 reopened from the durable checkpoint and the UI advanced directly to 627MB / 4.29GB rather than restarting from zero
- the upload atomically committed 4,294,967,296 bytes; the final UI reported attempt 2, 4.29GB / 4.29GB, and 31.7MB/s
- local and Android SHA-256 values matched; the managed checkpoint and queue manifest were removed after completion
- the disposable local source, Android partial, and Android final file were removed after verification
- the pre-existing 10GiB download-unplug source and 2GiB upload evidence file were left untouched

## Redacted Result Summary

```text
pre-crash authenticated upload: passed
durable checkpoint before SIGKILL: bytes=598999040
device-isolated manifest: present before crash
security-scoped bookmark: reacquired after relaunch
restored state: paused, explicit Resume required
resumed attempt: 2, checkpoint preserved
final upload: passed, bytes=4294967296, throughput=31.7 MB/s
sha256: matched
managed checkpoint cleanup: passed
disposable file cleanup: passed
```
