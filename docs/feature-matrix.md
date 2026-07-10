# Feature Matrix

| Feature | v1.0 | v1.1 | v1.5+ | Notes |
|---|---:|---:|---:|---|
| USB ADB connection | Yes | Yes | Yes | Stable production path. |
| USB AOA connection | PoC gated | Yes | Default candidate | Must pass throughput and reconnect gates. |
| File browsing | Yes | Yes | Yes | Android paging and Mac typed pager/presentation state exist; visual screen remains. |
| Upload/download | Yes | Yes | Yes | Resume required for large files. |
| Image albums | Yes | Yes | Yes | MediaStore first. |
| Video list/preview | Basic | Improved | Yes | Range streaming where useful. |
| Music management | Optional | Yes | Yes | Keep out of v1.0 critical path. |
| App list | Optional | Yes | Yes | Package visibility policy required. |
| APK install | Optional | Yes | Yes | User-confirmed system flow only. |
| Screen mirroring | No | No | Candidate | scrcpy/ADB and MediaProjection need separate design. |
| Notification mirroring | No | No | Candidate | Requires Android notification listener permission. |
| Clipboard sync | No | No | Candidate | Requires clear privacy controls. |
| Folder subscription | No | No | Candidate | Needs durable sync model. |
| Wi-Fi | No | No | Candidate | Must be complete: discovery + encryption + reconnect. |
