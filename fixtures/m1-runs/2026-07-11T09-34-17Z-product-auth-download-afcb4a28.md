# 2026-07-11 09:34:17Z Product Authentication and Download

status: passed
date: 2026-07-11 09:34:17Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local ad-hoc release Mac App from git 8e6fd2f-dirty; local debug Android APK
transport: paired-required ADB forward through the product launchers
handshake attempts: 2/2 passed (fresh post-pair authentication and Keychain-backed reconnect)
visible time: device already authorized over USB before the run
first list time: not separately timed; authenticated root and app-sandbox listings passed in the native UI
100MB download: not run; native product queue downloaded a disposable 1MiB source
100MB upload: not run
resume result: not run
permission cases: not run; Android reported zero SAF folders and product app-sandbox access passed
diagnostics bundle: authenticated product startup loaded privacy-bounded diagnostics; no exported bundle was retained

notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- both products displayed the same six-digit SAS; the transient value is intentionally omitted
- both visible approval controls were used; Android persisted trust and Mac persisted a non-synchronizing Keychain record
- the Mac App immediately authenticated a fresh session after pairing and later completed a Keychain-backed reconnect without another SAS ceremony
- after installing the timeout fix with `adb install -r`, a second visible-SAS run deliberately waited more than 35 seconds before approval; Android still showed 47 seconds remaining and pairing completed, proving the ordinary 30-second idle timeout no longer cancels human approval
- the authenticated root browser listed four provider roots and then loaded `dm://app-sandbox/`
- four heartbeat request/response pairs kept the product control session alive beyond Android's former 30-second idle boundary before the directory was opened
- the native save panel submitted a disposable 1MiB app-sandbox download to the product queue
- the transfer page reported completed, 1MiB / 1MiB, and 15.2 MiB/s; the local file size was verified as 1,048,576 bytes
- the disposable local destination and Android source were removed after verification
- two superseded Android trust records from the earlier ad-hoc attempts were removed through the product UI; the newest verified record remains available for follow-up product tests
- this run used the ordinary ad-hoc App; sandboxed file transfer remains a separate evidence item
- two pre-fix attempts exposed real product defects: Keychain list used an unsupported match-all data query, and the product control session had no idle heartbeat. The successful run used the fixes in this dirty worktree.

## Redacted Result Summary

```text
first pairing: passed with visible matching SAS on both products
fresh authenticated session: passed
trusted-device metadata refresh: passed
idle keepalive: 4/4 heartbeat responses across >30 seconds
slow visible approval: passed after >35 seconds
authenticated app-sandbox listing: passed, entries=3
native product download: passed, bytes=1048576, throughput=15.2 MiB/s
paired reconnect: passed without a new SAS ceremony
cleanup: passed
```
