# 2026-07-11 11:43:42Z Keystore Instrumentation Attempt

status: failed
date: 2026-07-11 11:43:42Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local debug Android target and instrumentation APKs from git 86b646d
transport: direct ADB instrumentation install, explicitly pinned to Slot C
handshake attempts: not run
visible time: device already authorized over USB before the run
first list time: not run
100MB download: not run
100MB upload: not run
resume result: not run
permission cases: instrumentation test APK installation rejected by OEM policy
diagnostics bundle: Gradle connected-test report retained only as local build output

notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- `connectedDebugAndroidTest` compiled both APKs but ran zero tests because Flyme returned `INSTALL_FAILED_USER_RESTRICTED` while installing `app.droidmatch.test`
- the Gradle connected-test installer removed the target product package before the rejected test-APK step; this erased the product's private test files and paired-device application state
- the debug product APK was reinstalled successfully; the disposable 10GiB download-unplug source and retained 2GiB upload evidence file must be recreated before those follow-up scenarios
- a repository runner was added after the failure. It requires the product package to exist, installs the test APK before instrumentation, and removes only the test package
- the repository runner was exercised against the same MEIZU: it returned status 3 for the OEM rejection and verified that the product package remained installed
- the two Keystore instrumentation tests remain unexecuted and must not be described as passing

## Redacted Result Summary

```text
instrumentation compile: passed
test APK install: failed, INSTALL_FAILED_USER_RESTRICTED
tests executed: 0
unsafe Gradle target uninstall observed: yes
product APK restored: yes
safe repository runner regression tests: passed
safe runner on MEIZU: rejected without removing product
Keystore physical-device criterion: open
```
