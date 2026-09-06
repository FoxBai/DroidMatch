# Feature Matrix

This is a release-planning matrix, not a current implementation checklist.
Use [M1 Status](m1-status.md) for implemented behavior and accepted evidence.

| Feature | v1.0 target | v1.1 target | Later | Notes |
|---|---:|---:|---:|---|
| USB ADB connection | Required | Required | Required | Current authenticated product path; remaining M1 device evidence is tracked in the status page. |
| USB AOA connection | Experimental if gated | Candidate | Default candidate | Must pass the documented throughput, reconnect, and device gates before promotion. |
| Pairing and trusted reconnect | Required | Required | Required | Visible first-pairing SAS and paired proof are implemented on the ADB product path. |
| File browsing and mutation | Required | Required | Required | Paging, search, sort, create, rename, delete, multi-select, and capability-aware actions are implemented. |
| Upload and download queue | Required | Required | Required | Persistent native-panel/Finder admission; resumable App Sandbox/SAF transfers; fresh-only MediaStore creation. |
| Image albums | Required | Required | Required | Separate media surface with MediaStore albums, bounded thumbnails, preview, and live access recheck. |
| Video list and preview | Basic | Improved | Full | Static preview and duration metadata are implemented. Native play/pause/seek for supported MediaStore video containers now uses bounded authenticated range reads; local synthetic playback evidence exists, while device playback/codec coverage remains open. |
| Diagnostics and support export | Required | Required | Required | Privacy-bounded structured diagnostics; raw serials, paths, credentials, and exceptions stay out. |
| Signed macOS distribution | Required for release | Required | Required | Local ad-hoc App/DMG validation exists; Developer ID signing and notarization are deferred pre-release work. |
| Music management | Optional | Required | Required | Basic list/search/sort/duration/import/export and live audio authorization are implemented; playback, artwork, and artist/album indexing remain later work. Device validation is open. |
| App list and APK install | Optional | Improved | Required | Requires package-visibility policy and a user-confirmed platform install flow. |
| Screen mirroring | No | No | Candidate | Requires a separate scrcpy/ADB or MediaProjection design. |
| Notification mirroring | No | No | Candidate | Requires explicit notification-listener permission and privacy design. |
| Clipboard sync | No | No | Candidate | Requires clear direction, consent, and history controls. |
| Folder subscription | No | No | Candidate | Requires a durable conflict and synchronization model. |
| Wi-Fi transport | No | No | Candidate | Must ship as a complete discovery, encryption, and reconnect design rather than a partial mode. |
