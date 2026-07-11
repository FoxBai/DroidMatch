# 2026-07-11 10:07:39Z Sandboxed Product Transfer

status: passed
date: 2026-07-11 10:07:39Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local ad-hoc-signed sandbox release Mac App from a dirty `codex/fix-sandbox-transfer-scope` worktree; local debug Android APK
transport: paired-required ADB forward through the product launchers
handshake attempts: 1/1 passed after visible-SAS pairing
visible time: device already authorized over USB before the run
first list time: not separately timed; authenticated app-sandbox listing passed in the native UI
100MB download: not run; native product queue downloaded a disposable 1MiB source
100MB upload: not run; native product queue uploaded a disposable 1MiB source
resume result: persistence paths were exercised; interruption/relaunch was not forced in this run
permission cases: sandbox directory bookmark for download and single-file bookmark for upload both passed
diagnostics bundle: not exported

notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- both products displayed the same six-digit SAS; the transient value is intentionally omitted
- the sandbox-entitled Mac bundle used its embedded adb, authenticated, and listed `dm://app-sandbox/`
- the native download flow explicitly selected a destination directory so the final file, partial file, and download checkpoint share one security-scoped authorization and filesystem
- a temporary-directory selection did not produce a usable persistent security-scoped bookmark on this host; the successful product run selected a normal user-authorized directory, then removed the disposable output
- the 1MiB download completed with matching local and Android SHA-256 values
- the upload selected one source file through the native open panel; its durable checkpoint lived in the device-isolated App-owned transfer directory rather than beside the read-only-authorized source
- the 1MiB upload completed with matching local and Android SHA-256 values; no adjacent source sidecar remained, and the App-owned upload-checkpoint directory was empty after completion
- all disposable Mac and Android transfer files were removed after verification; the pre-existing large files reserved for physical-download-unplug testing were left untouched
- the successful run used fixes from this dirty worktree. Repository gates and hosted CI are required before this evidence can support a merged status claim.

## Redacted Result Summary

```text
sandbox bundle and embedded adb: passed
visible-SAS pairing and authentication: passed
authenticated app-sandbox listing: passed
native sandbox download: passed, bytes=1048576, sha256=matched
download directory scope: passed
native sandbox upload: passed, bytes=1048576, sha256=matched
App-owned upload checkpoint: passed, no adjacent source sidecar
cleanup: passed
```
