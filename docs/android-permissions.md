# Android Permissions

## Principle

DroidMatch must treat Android permissions as live capability state. The Mac app should never assume the Android service can access every file or package.

## v1 Permission Matrix

| Capability | Preferred Path | Degradation |
|---|---|---|
| Public media | MediaStore | Ask user to grant selected folder access. |
| General files | SAF / user-selected roots | Show public folders and explain limits. |
| Upload to protected paths | User-selected writable root | Mark path read-only. |
| APK install | System install confirmation | Explain unknown-source requirement. |
| App list | PackageManager under visibility policy | Show visible packages only. |
| App uninstall | System uninstall intent | No silent uninstall. |
| Screen mirror | Not v1.0 | Separate v1.5 design. |
| Foreground service notification | Runtime `POST_NOTIFICATIONS` on Android 13+ | Continue the harness but report `notifications` as needing user action. |
| Notification mirroring | Not v1.0 | Notification listener permission required later. |

## Distribution

Do not assume one Android build fits every channel.

Potential channels:

- GitHub Releases / website.
- F-Droid.
- Google Play.
- Domestic Android app stores.

Feature flags should allow channel-specific restrictions without forking the protocol.

## Android 11+ Storage Behavior

Android 11+ scoped storage is the primary design target.

- Public images and videos should use MediaStore first.
- General file browsing should use user-selected roots through the Storage Access Framework.
- Paths outside granted roots must be hidden, read-only, or represented as unavailable.
- Uploads must target a writable user-selected root or a MediaStore collection.
- Directory listings must include `can_read` and `can_write` so the Mac app can degrade controls without guessing.
- M1 obtains SAF access through the Android system directory picker and stores persisted tree URI permissions. The protocol exposes those roots only as `dm://saf-.../` logical paths.
- Permission changes must be reported as live capability changes and invalidate affected caches.
- Android 13+ requires runtime `POST_NOTIFICATIONS` for the foreground service notification. M1 requests it from the debug harness and diagnostics entry points, but a denial must not block ADB smoke tests; diagnostics and `DeviceInfoResponse.permissions["notifications"]` carry the current state.

## Android 8-10 Storage Behavior

Android API 26-29 devices are supported, but v1.0 should not build a second primary file model for legacy storage.

- SAF user-selected roots and MediaStore remain the preferred paths on API 26-29.
- `READ_EXTERNAL_STORAGE` may be requested to improve public media indexing when the build channel allows it.
- `WRITE_EXTERNAL_STORAGE` is not part of the default Google Play path; uploads should still target SAF writable roots or MediaStore collections.
- Direct File API access to shared storage is optional, non-default, and must be capability-gated for non-Play or experimental builds.
- If direct File API access is enabled, the provider must still return `can_read`, `can_write`, and permission state so the Mac app uses the same degradation model.
- API 26-29 permission grants must be treated as live state and must invalidate affected caches just like Android 11+ permission changes.

## Play and Non-Play Builds

The protocol must support channel-specific capability differences.

- Google Play builds should avoid broad storage and broad package visibility unless the product later qualifies under current store policy.
- Non-Play builds may expose optional broad-file or package-management capabilities behind explicit feature flags and user-facing permission explanations.
- APK install, APK backup, and app-list features must be capability-gated so a restricted build can hide them cleanly.
- Build channel differences must be visible through capability negotiation and diagnostics.

## Package Visibility Policy

- v1.0 should request the narrowest package visibility needed for optional app metadata features.
- `QUERY_ALL_PACKAGES` is not part of the default Google Play build plan.
- Package listing must degrade to visible packages only when broad visibility is unavailable.
- Silent install and silent uninstall are out of scope; system confirmation flows are required.
- Diagnostics should report whether package results are complete, filtered by policy, or unavailable.
