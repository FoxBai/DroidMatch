# 2026-07-11 16:30:00Z Android Keystore Instrumentation

status: passed
date: 2026-07-11 16:30:00Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local debug and isolated instrumentation APKs from git 2a316b3
transport: explicit ADB serial; repository safe instrumentation runner
handshake attempts: not run
visible time: user was present and manually approved the OEM test-APK install prompt
first list time: not run
100MB download: not run
100MB upload: not run
resume result: not run
permission cases: attended test-APK installation allowed; two isolated Keystore tests passed
diagnostics bundle: not run
notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- stable P-256 identity remained non-exportable and signed a verification transcript
- AES wrapping key remained non-exportable; encrypted pairing record reopen and revoke succeeded
- instrumentation result: `OK (2 tests)`
- attended limitation: this run required the user to tap Allow on the phone; it is not unattended-install evidence
- cleanup verification: `app.droidmatch.test` was absent after runner exit
- product preservation: `app.droidmatch` first-install and last-update timestamps were unchanged
