# Product Scope

## Goal

DroidMatch v1.0 should replace the highest-value HandShaker workflows with a modern, native, diagnosable implementation.

## Platform Baseline

- Minimum macOS: macOS 13 Ventura.
- Minimum Android API: API 26, Android 8.0.
- Target Android SDK: latest stable SDK available at implementation time.
- Android 11+ scoped storage behavior is the primary permission model; older Android versions are supported on a best-effort basis through the same provider interfaces.

## v1.0

Must have:

- USB device discovery and connection.
- ADB stable path.
- AOA path if M1 PoC meets acceptance thresholds; otherwise ship as beta/experimental.
- Device information: model, Android version, capacity, battery, connection mode, permission status.
- File browsing: list, search, sort, create folder, rename, delete, upload, download, drag and drop, multi-select.
- Transfer queue: progress, pause, cancel, retry, resume, failure recovery.
- Basic image management: MediaStore albums, thumbnails, preview, import/export.
- Basic video management: list, thumbnails, preview where practical.
- Diagnostics panel: ADB/AOA state, Android service state, permission state, ports, recent errors, log export.
- Android foreground service and permission guide.
- macOS signing, notarization, DMG packaging.
- Simplified Chinese and English.

May have:

- Basic music list and import/export.
- APK install flow.
- APK backup export.
- Application package metadata display.

Not in v1.0:

- Wi-Fi.
- SMS, calls, contacts.
- Screen mirroring.
- Notification mirroring.
- Clipboard sync.
- Folder subscription.
- Cloud account or relay service.
- HandShaker brand, icon, UI, or binary asset reuse.
- HandShaker protocol compatibility outside an isolated, timeboxed research adapter.

## v1.1

- Music metadata and album/artist/song views.
- Stronger video preview.
- Application management improvements.
- Thumbnail cache and indexing improvements.
- Batch operation polish.

## v1.5

- AOA as the default connection path if proven stable.
- Screen mirroring.
- Clipboard sync.
- Notification mirroring.
- Android-to-Mac folder subscription.
- Full Wi-Fi design investigation: mDNS + TLS + QUIC, no half-finished Wi-Fi mode.
