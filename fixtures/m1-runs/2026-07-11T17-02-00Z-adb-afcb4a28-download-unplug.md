# 2026-07-11 17:02:00Z Attended Physical Download Unplug

status: passed
date: 2026-07-11 17:02:00Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: already-installed local debug APK; Mac runner from git `d013481`
transport: ADB forward to debug harness Activity endpoint
handshake attempts: not run; the transfer runner opened a fresh negotiated session before each phase
visible time: user physically unplugged and reconnected the selected device
first list time: not run
100MB download: not run; dedicated 10GiB interruption scenario used instead
100MB upload: not run
source provider: disposable app-sandbox test file
source bytes: 10737418240
durable partial bytes after disconnect: 3626762240
resumed bytes: 7110656000
final bytes: 10737418240
resume result: passed (`resume=true`)
permission cases: not run; app-sandbox source was already authorized
diagnostics bundle: not run; aggregate runner output is included below
resume elapsed: 239184 ms
resume throughput: 28.35 MiB/s
notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- runner required the selected serial to disappear from `adb devices`; an
  `offline` or `unauthorized` state was not accepted as physical disconnect.
- the first connection closed while reading a frame header, after the partial
  file and checkpoint sidecar were durable.
- the same selected serial returned ready with a new ADB transport identity.
- a new dynamic forward was created for resume and removed on exit; two
  pre-existing forwards were not modified.
- the final local file size matched the exact source size; the partial and
  sidecar were removed by the atomic commit.
- the caller removed the disposable local 10 GiB result after verification.
- this is attended evidence: the user performed the physical unplug/reconnect.
  It is not an unattended hardware-automation claim.

## Redacted Runner Output

```text
UNPLUG NOW: physically disconnect the selected Android device.
download failed: connection closed while reading frame header
DISCONNECT OBSERVED: durable partial bytes=3626762240. Reconnect the same device.
download passed chunks=27125 bytes=7110656000 total=10737418240 final_offset=10737418240 elapsed_ms=239184 throughput_mib_per_sec=28.35 resume=true retry_attempts=1 recovered=false destination=<local-file>
physical download interruption/resume passed final_bytes=10737418240
```
