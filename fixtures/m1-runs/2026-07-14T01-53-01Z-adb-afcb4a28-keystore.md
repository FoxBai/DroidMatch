# 2026-07-14 01:53:01Z Android Keystore Instrumentation

status: passed
date: 2026-07-14 01:53:01Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local debug and isolated instrumentation APKs from git aaf332a
transport: explicit ADB serial; repository safe instrumentation runner
handshake attempts: not run
visible time: device was already authorized; OEM test-APK installation completed successfully
first list time: not run
100MB download: not run
100MB upload: not run
resume result: not run
permission cases: two isolated Keystore tests passed
diagnostics bundle: not run
notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- stable P-256 identity remained non-exportable and signed a verification transcript
- AES wrapping key remained non-exportable; encrypted pairing record reopen and revoke succeeded
- instrumentation result: `OK (2 tests)`
- cleanup verification: `app.droidmatch.test` was absent after runner exit
- product preservation boundary: `app.droidmatch` remained installed; the safe runner never requested product uninstall
