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
| Notifications | Not v1.0 | Notification listener permission required later. |

## Distribution

Do not assume one Android build fits every channel.

Potential channels:

- GitHub Releases / website.
- F-Droid.
- Google Play.
- Domestic Android app stores.

Feature flags should allow channel-specific restrictions without forking the protocol.

