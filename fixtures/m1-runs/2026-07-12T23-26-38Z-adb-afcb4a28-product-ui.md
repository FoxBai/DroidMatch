# 2026-07-12 23:26:38Z Product Pairing and Reconnect

status: passed
date: 2026-07-12 23:26:38Z
device slot: C
manufacturer/model: meizu MEIZU M20
android version/api: Android 14 / API 34
build channel: local ordinary debug product bundle and debug APK from git `be7102c`
transport: product-owned dynamic loopback ADB forward to paired-required secure USB
handshake attempts: first pairing passed; saved-pairing disconnect/reconnect passed without another SAS prompt
visible time: product Mac and Android surfaces were operated under the user's explicit physical-test authorization
first list time: not measured; the authenticated product file browser rendered its live root rows before and after reconnect
100MB download: not run through the product UI in this session
100MB upload: not run through the product UI in this session
resume result: not run; the empty persistent queue reported healthy recovery storage
permission cases: not mutated; the product Android launcher, pairing approval, trusted-Mac, and secure-USB controls were exercised
diagnostics bundle: structured product diagnostics loaded with privacy-bounded health and paired-proof verification; export not run
notes:

- serial redaction tag: `<serial-redacted:afcb4a28>`
- the Mac and Android six-digit SAS values were compared locally; equality was true, and neither value was logged or archived
- Android persisted one trusted-Mac entry and cleared the pending approval after finalize
- the Mac persisted the pairing credential in its product credential store and authenticated the reconnect without presenting another pairing sheet
- file browsing remained unlocked after reconnect, with live root rows and upload affordance available
- the transfer surface showed an empty secure queue and did not report unavailable recovery storage
- after the final disconnect, the product-owned ADB forward count was `0`; Android secure USB was then stopped while pairing trust was retained
- post-run cleanup verification found `0` rows for the exact disposable MediaStore upload name, `0` default local download/partial/sidecar artifacts, and `0` known temporary upload sources
- this is product-surface evidence, not a claim that product UI transfer interruption/resume or Developer ID release signing passed in this session
