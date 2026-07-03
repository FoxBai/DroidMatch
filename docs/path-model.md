# Path Model

DroidMatch protocol paths are logical provider paths. They are not raw Android filesystem paths, raw SAF URIs, Mac POSIX paths, or user-visible display strings.

## Goals

- Keep Mac UI and transfer logic independent from Android provider implementation details.
- Avoid exposing SAF `content://` URIs or vendor-specific storage paths to the Mac side.
- Keep path comparison, paging, transfer resume, and cache invalidation deterministic.
- Allow Android providers to change implementation without changing the protocol surface.

## Logical Path Format

M1 uses this canonical path format:

```text
dm://<root-id>/<percent-encoded-relative-path>
```

Rules:

- `root-id` is an opaque ASCII identifier assigned by the Android provider.
- The root path is `dm://<root-id>/`.
- Relative path segments are separated by `/`.
- Path segments must be UTF-8 percent-encoded when they contain `/`, `%`, control characters, or bytes that are not valid display text.
- `.` and `..` are invalid path segments.
- Duplicate `/` separators are invalid.
- Paths are case-sensitive unless a provider explicitly reports otherwise in future capabilities.
- Mac-local paths are never sent as Android provider paths.

Examples:

```text
dm://roots/
dm://media-images/DCIM/Camera/IMG_0001.jpg
dm://saf-primary/Download/archive.zip
dm://app-sandbox/export/report.pdf
```

M1 reserves `dm://roots/` as a virtual read-only directory that lists the
provider roots currently exposed by the Android service. The entries returned
from this directory are still canonical provider paths such as
`dm://media-images/` and must be treated like any other `FileEntry`.

`dm://media-images/` and `dm://media-videos/` are backed by Android MediaStore
in M1. Their first implementation returns flat media entries using stable
logical item paths such as `dm://media-images/media/42`; folder grouping and
bucket browsing stay out of the first smoke path.

Persisted SAF roots appear as `dm://saf-<stable-id>/` entries under
`dm://roots/`. Child documents use opaque logical tokens such as
`dm://saf-abc123/doc/9f4c2a7b6d001234`; raw `content://` URIs and Android
document IDs must not be logged or shown as provider paths.
These SAF document tokens are process-local capabilities backed by a bounded
Android-side cache, not permanent document IDs. Clients must be prepared for an
old token to return `ERROR_CODE_NOT_FOUND` after cache eviction, permission
revocation, provider mutation, or service restart.

Fresh upload into a writable SAF directory appends a display-name segment to the
directory path. The root form is `dm://saf-<stable-id>/<display-name>`; a listed
directory uses `dm://saf-<stable-id>/doc/<directory-token>/<display-name>`.
The display name is a single path segment and must not contain `/`. SAF upload
resume is out of scope until Android can persist and validate provider partial
state safely.

## Android Provider Mapping

Android providers own the mapping from logical paths to platform APIs:

- Media roots map to MediaStore collections and stable media IDs where possible.
- SAF roots map to persisted tree URI permissions on Android.
- App-private roots map to app-owned storage; M1 exposes `dm://app-sandbox/` from the Android app's `files/droidmatch-sandbox` directory.
- Optional non-Play legacy roots may map to direct File API access on API 26-29.

The Mac side must not infer Android access method from `root-id`. It should use `FileEntry.can_read`, `FileEntry.can_write`, negotiated capabilities, and permission diagnostics.

## Mac Path Handling

Mac POSIX paths are local UI and harness concerns. The protocol may include `destination_path` or `source_path` fields for transfer bookkeeping, but Android providers should only act on paths that are meaningful for the Android side:

- Download: Android validates `source_path`; Mac validates local destination separately.
- Upload: Android validates `destination_path`; Mac validates local source separately.

In M1, the inactive side path may be present for diagnostics but must not be used for authorization decisions by the peer.

## Listing and Mutation Semantics

- `ListDirRequest.path` must be a logical directory path.
- `FileEntry.path` must be a canonical logical path returned by the provider.
- `CreateDirectoryRequest.path` creates one logical directory.
- `DeletePathRequest.path` deletes one logical path; recursive deletion is allowed only when `recursive = true`.
- `RenamePathRequest.source_path` and `destination_path` must belong to the same provider root in M1.

Cross-root moves are out of scope for M1. The Mac app should implement those as copy plus delete only after transfer and mutation behavior is proven.

## Page Tokens

`page_token` is opaque and provider-owned.

- Empty token starts a new listing.
- Tokens may encode provider root, query, sort order, permission snapshot, and cursor position.
- Tokens must not expose raw SAF URIs, filesystem paths, or personal file names in logs.
- A token is valid only for the exact `path`, `page_size`, `sort_field`, and `descending` values that produced it.
- Permission changes, root revocation, mutations under the listed directory, or provider restart may invalidate tokens.
- Invalid tokens return `ERROR_CODE_INVALID_ARGUMENT` with a user-safe message and a diagnostic detail.

M1 providers should cap `page_size` to 1,000 entries. If a request uses `page_size = 0`, the provider chooses a default of 200 entries.

## Cache Keys

Path-based caches should include:

- Device identity.
- Protocol major version.
- Provider root ID.
- Canonical logical path.
- Permission snapshot.
- Sort and paging parameters when caching list results.

Permission changes and mutations invalidate affected path caches.
