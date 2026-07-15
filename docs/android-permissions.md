# Android Permissions

## Principle

DroidMatch must treat Android permissions as live capability state. The Mac app should never assume the Android service can access every file or package.

## v1 Permission Matrix

| Capability | Preferred Path | Degradation |
|---|---|---|
| Public media | MediaStore | After an explicit product action, request the applicable media permission or selected photos/videos; this is not a SAF folder grant. |
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
- Android 13+ requires runtime `POST_NOTIFICATIONS` for the foreground service notification. M1 requests it from the product launcher and debug harness/diagnostics entry points, but a denial must not block ADB smoke tests; diagnostics and `DeviceInfoResponse.permissions["notifications"]` carry the current state.

## Product Media Authorization

Media authorization is requested only after the user presses the photo/video
control in `DroidMatchActivity`; launcher startup never opens the media chooser.
The request set is versioned with the platform:

- API 26–32: `READ_EXTERNAL_STORAGE`.
- API 33: `READ_MEDIA_IMAGES` and `READ_MEDIA_VIDEO`.
- API 34+: both media permissions and
  `READ_MEDIA_VISUAL_USER_SELECTED` in one operation, so the same explicit
  control can also reselect photos and videos.

The launcher recomputes state after the permission result and whenever it
returns to the foreground. Its user-facing summary is `FULL`, `LIMITED`, or
`DENIED`. `LIMITED` means either Android 14 selected-item access or that only
one of images/videos has broad access; it never means a SAF folder grant.
Cancelling the chooser does not redirect to Settings. If Android no longer
offers a missing broad permission, the same user-triggered control changes to
an explicit Settings action; an unavailable OEM Settings intent fails without
crashing the launcher.

Each `dm://roots/` response is a point-in-time capability snapshot. Images and
Image Albums follow current image access; Videos follows current video access.
Full and selected access publish `can_read=true`, while denied access publishes
false. Selected access may still produce an empty root when no selected item
matches that media type. `can_write` is independent: API 29+ may accept an
app-owned fresh MediaStore insert without media read access, so the Mac can
offer a root-level upload without listing the root. API 26–28 do not advertise
MediaStore upload because the default manifest deliberately omits
`WRITE_EXTERNAL_STORAGE`; writable SAF remains available there.

The wire shape is unchanged. `FileEntry.can_read` is boolean and diagnostics
retain their coarse granted/needs-user-action state; neither exposes the
launcher summary or a full-vs-selected enum. The snapshot is not an
authorization token: list, thumbnail, open, and every active provider chunk
continue to re-check live access and may fail after a permission change.

## Android 8-10 Storage Behavior

Android API 26-29 devices are supported, but v1.0 should not build a second primary file model for legacy storage.

- SAF user-selected roots and MediaStore remain the preferred paths on API 26-29.
- `READ_EXTERNAL_STORAGE` may be requested to improve public media indexing when the build channel allows it.
- `WRITE_EXTERNAL_STORAGE` is not part of the default build. API 26–28 therefore use writable SAF for uploads instead of advertising an unusable MediaStore destination; API 29 uses app-owned scoped MediaStore inserts.
- Direct File API access to shared storage is optional, non-default, and must be capability-gated for non-Play or experimental builds.
- If direct File API access is enabled, the provider must still return `can_read`, `can_write`, and permission state so the Mac app uses the same degradation model.
- API 26-29 permission grants must be treated as live state and must invalidate affected caches just like Android 11+ permission changes.

## Foreground Service Lifecycle

- The ADB harness uses the `dataSync` foreground-service type deliberately. Its transport is loopback TCP reached through ADB forwarding, so the app does not hold the Bluetooth, UWB, network-state, or `UsbManager` grant required for `connectedDevice` on Android 14+.
- The service is non-exported in both release and debug builds. Debug automation starts the exported `DebugHarnessActivity`, which then starts the service with an explicit in-app intent.
- The service returns `START_NOT_STICKY`; after process death, the user or harness must reconnect explicitly instead of leaving an idle foreground service without endpoint parameters.
- Android 15 limits background `dataSync` foreground services to a shared six-hour budget per 24 hours. When Android calls `onTimeout()`, DroidMatch closes the ADB endpoint and stops the service immediately.
- A future AOA transport may add `connectedDevice` only after it obtains a real accessory grant through `UsbManager.requestPermission()`.

## Play and Non-Play Builds

The protocol must support channel-specific capability differences.

- Google Play builds should avoid broad storage and broad package visibility unless the product later qualifies under current store policy.
- Supporting Android 14 selected media does not by itself make the broad
  `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` declarations eligible or approved
  for Google Play; distribution still requires the applicable core-use
  declaration and review.
- Non-Play builds may expose optional broad-file or package-management capabilities behind explicit feature flags and user-facing permission explanations.
- APK install, APK backup, and app-list features must be capability-gated so a restricted build can hide them cleanly.
- Build channel differences must be visible through capability negotiation and diagnostics.

## Package Visibility Policy

- v1.0 should request the narrowest package visibility needed for optional app metadata features.
- `QUERY_ALL_PACKAGES` is not part of the default Google Play build plan.
- Package listing must degrade to visible packages only when broad visibility is unavailable.
- Silent install and silent uninstall are out of scope; system confirmation flows are required.
- Diagnostics should report whether package results are complete, filtered by policy, or unavailable.

## Backup and Device Transfer

- DroidMatch sets `allowBackup=false` and supplies explicit pre-Android-12 full-backup plus Android-12+ data-extraction rules.
- Cloud backup and device-to-device transfer exclude root, file, database, shared-preference, external, and device-protected storage domains.
- Pairing key ciphertext, Android Keystore metadata, persisted SAF state, transfer metadata, diagnostics, and cached filenames must never move through platform backup.
- Moving to a new phone requires a fresh pairing; backup restore is not a credential-recovery mechanism.
