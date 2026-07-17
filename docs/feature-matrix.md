# Feature Matrix

| Feature | v1.0 | v1.1 | v1.5+ | Notes |
|---|---:|---:|---:|---|
| USB ADB connection | Yes | Yes | Yes | Stable harness path; native Mac discovery shell now lists devices without exposing serials, while authenticated product session wiring remains. |
| USB AOA connection | PoC gated | Yes | Default candidate | Must pass throughput and reconnect gates. |
| File browsing | Yes | Yes | Yes | Authenticated Mac product session includes paging, provider-side search/sort, mutations, selection, and transfers. Files hides media roots; the independent Media section is the sole product media entry, and its image, album, and video browsers retain separate navigation state while access recheck fail-closes cached display data. |
| Upload/download | Yes | Yes | Yes | Native panel and Finder drop both admit at most 100 ordered, normalized-name-unique regular files through one tested policy; each upload or selected download persists independently, and zero/partial batch admission is disclosed without claiming rollback. A model-wide single-flight serializes admission across file/media and single/batch entry points before bookmark, manifest, or scheduler side effects without limiting execution of accepted queue jobs. Search, selection, row/context actions, navigation, and media switching are disabled for the same admission lifetime; batch reconciliation removes only accepted inputs from current selection, so neither partial retry nor a late full success can overwrite unrelated state. Unhealthy/retrying persistence and bulk cleanup disable new transfer entry points before a native panel opens and expose an in-place retry warning without blocking browsing or remote mutations. The transfer page also presents unknown/retrying recovery state as pending rather than healthy, disables pause/resume/cancel/remove/cleanup until authoritative storage readiness is known, and turns any late action rejection into fixed privacy-bounded feedback. The queue clears only settled successful history, retains other outcomes, and shows localized next steps for retrying/failed/interrupted rows from exact allowlisted reason codes; raw or extended failure text never enters presentation. Resume is required for large app-sandbox/SAF transfers, while MediaStore creation stays fresh-only. |
| Image albums | Yes | Yes | Yes | Independent Media section plus MediaStore bucket view with opaque album tokens, lazy covers, canonical media item identity, bounded hidden-browser derivative work, and fresh-only media upload disclosure/type checks. |
| Video list/preview | Basic | Improved | Yes | Range streaming where useful. |
| Music management | Optional | Yes | Yes | Keep out of v1.0 critical path. |
| App list | Optional | Yes | Yes | Package visibility policy required. |
| APK install | Optional | Yes | Yes | User-confirmed system flow only. |
| Screen mirroring | No | No | Candidate | scrcpy/ADB and MediaProjection need separate design. |
| Notification mirroring | No | No | Candidate | Requires Android notification listener permission. |
| Clipboard sync | No | No | Candidate | Requires clear privacy controls. |
| Folder subscription | No | No | Candidate | Needs durable sync model. |
| Wi-Fi | No | No | Candidate | Must be complete: discovery + encryption + reconnect. |
