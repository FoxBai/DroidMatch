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
in M1. Their flat views return stable logical item paths such as
`dm://media-images/media/42`. `dm://media-images/albums/` is a separate virtual
root listed under `dm://roots/`; its children use non-reversible logical tokens
such as `dm://media-images/albums/4f2a.../`. An album is a filtering view, not a
second identity namespace: rows inside it retain the same canonical
`dm://media-images/media/<id>` paths used by the flat view. Android resolves the
token against MediaStore `BUCKET_ID` without exposing the bucket ID, filesystem
path, or content URI to Mac.
Album tokens are exactly 24 lowercase hexadecimal characters. A thumbnail
request may target an album directory to obtain a bounded derivative of its
latest available image; malformed tokens are rejected before any MediaStore
scan, and the virtual album root remains read-only even when image upload is
available.
Fresh upload into a MediaStore collection appends a display-name segment to the
collection root: `dm://media-images/<display-name>` for images and
`dm://media-videos/<display-name>` for videos. The display name is a single path
segment and must not contain `/`. MediaStore upload resume is out of scope until
Android can persist and validate provider partial state safely.

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
Current Mac upload clients therefore put the shared opaque label
`mac-local-upload` in wire `source_path`; the real POSIX source remains only in
Mac-local sidecars for resume identity validation. Normal harness success output
uses `<local-file>` / `<local-partial>` / `<local-sidecar>` placeholders.
The native transfer presentation boundary follows the same ownership split: Core
retains the exact local path, while a row item receives only its basename plus
an optional remote path after a `dm://` scheme check. Raw Core failure text is
not copied into row state because a local file or sidecar error may contain an
absolute path.

The current product uploader appends one local basename only to an authenticated,
writable app-sandbox, MediaStore-root, SAF-root, or opaque SAF-directory path.
Names containing `/`, `%`, control characters, bidirectional formatting controls,
`.` or `..` are rejected before queue submission. Percent-bearing names remain
unsupported until both platforms share one segment decoder; sending an apparently
encoded path that Android treats as a literal display name would violate canonical
path identity. MediaStore destinations are fresh-only and are never replayed by
the product retry policy.

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
- Mac clients must treat tokens as opaque bytes-in-a-string: do not parse, log, normalize, or synthesize them. The exact query tuple that produced a token must be reused.

M1 providers should cap `page_size` to 1,000 entries. If a request uses `page_size = 0`, the provider chooses a default of 200 entries.

The product Mac domain uses an explicit default of 200 and accepts 1...1,000. It
maps provider-unknown size/timestamp fields to optional values, requires each row
to have a unique logical `dm://` path within its page, and filters duplicate paths
across pages without interpreting the token. `dm://roots/` is a virtual directory:
its returned provider-root paths are not children by string-prefix, so clients
must not enforce a request-path prefix rule on listing rows.

## Cache Keys

Path-based caches should include:

- Device identity.
- Protocol major version.
- Provider root ID.
- Canonical logical path.
- Permission snapshot.
- Sort and paging parameters when caching list results.

Permission changes and mutations invalidate affected path caches.
