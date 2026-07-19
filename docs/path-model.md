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
- `dm://` alone identifies only the scheme; it is not a provider path and is
  invalid as either endpoint of a mutation.

Examples:

```text
dm://roots/
dm://media-images/media/42
dm://saf-primary/Download/archive.zip
dm://app-sandbox/export/report.pdf
```

M1 reserves `dm://roots/` as a virtual read-only directory that lists the
provider roots currently exposed by the Android service. The entries returned
from this directory are still canonical provider paths such as
`dm://media-images/` and must be treated like any other `FileEntry`.

Every root listing is a point-in-time capability snapshot, not an authorization
token. Images and Image Albums follow the live image permission; Videos follows
the live video permission; App Sandbox is readable; SAF exposes only roots that
still have a readable persisted grant. Full or Android 14 selected-media access
publishes `can_read=true`, while denied media access publishes false. A selected
root can still be empty when no selected item belongs to that media type.
`can_write` is independent: on API 29+ a MediaStore root can be unreadable but
still accept a fresh app-owned upload. The product Files surface filters the
three built-in media roots from its root projection; Media is the sole product
UI that consumes them, refuses to browse an unreadable container without another
list request, and retains a direct root upload when `can_write=true`. Android
re-authorizes each operation and active provider chunk, so any later permission
change may still return `ERROR_CODE_PERMISSION_REQUIRED` or close the transport.

`dm://media-images/` and `dm://media-videos/` are backed by Android MediaStore
in M1. Their flat views return stable logical item paths such as
`dm://media-images/media/42`. `dm://media-images/albums/` is a separate virtual
root listed under `dm://roots/`; its children use non-reversible logical tokens
such as `dm://media-images/albums/4f2a.../`. An album is a filtering view, not a
second identity namespace: rows inside it retain the same canonical
`dm://media-images/media/<id>` paths used by the flat view. Android resolves the
token against MediaStore `BUCKET_ID` without exposing the bucket ID, filesystem
path, or content URI to Mac.
The `<id>` segment is a non-negative decimal MediaStore row ID and
must fit a signed 64-bit integer. Empty, sign-bearing, non-decimal,
slash-containing, and overflow forms are invalid; Mac rejects them before a
thumbnail request reaches the wire, and Android applies the same provider-path
constraint.
Album tokens are exactly 24 lowercase hexadecimal characters. A thumbnail
request may target an album directory to obtain a bounded derivative of its
latest available image; malformed tokens are rejected before any MediaStore
scan, and the virtual album root remains read-only even when image upload is
available.
Fresh upload into a MediaStore collection appends a display-name segment to the
collection root: `dm://media-images/<display-name>` for images and
`dm://media-videos/<display-name>` for videos. The display name is a single path
segment and must not contain `/`. Its case-insensitive extension must also match
the explicit image/video allowlist shared by the Mac product boundary and Android
provider policy; unknown, extensionless, ambiguous `.ts`, and cross-category names
fail before Android inserts a MediaStore row. This validates the declared filename
type rather than decoding the complete payload. The current case-insensitive image
set is `avif/bmp/dng/gif/heic/heif/jpeg/jpg/png/tif/tiff/webp`; the video set is
`3gp/3gpp/avi/m2ts/m4v/mkv/mov/mp4/mpeg/mpg/ogv/webm`. MediaStore upload resume is out of scope until
Android can persist and validate provider partial state safely.

Persisted SAF roots appear as `dm://saf-<stable-id>/` entries under
`dm://roots/`. Child documents use opaque logical tokens such as
`dm://saf-abc123/doc/9f4c2a7b6d001234`; raw `content://` URIs and Android
document IDs must not be logged or shown as provider paths.
These SAF document tokens are process-local capabilities backed by a bounded
Android-side cache, not permanent document IDs. Clients must be prepared for an
old token to return `ERROR_CODE_NOT_FOUND` after cache eviction, permission
revocation, provider mutation, or service restart.

App-sandbox upload partials live in an app-private sibling staging directory,
outside `dm://app-sandbox/`. Their filenames contain only domain-separated
digests of the canonical logical destination, stable transfer ID, and expected
size. The sibling staging node must be a real directory under no-follow checks;
an ordinary file or symbolic link at that path is rejected intact. A fresh open
removes only older matching regular-file partials for that exact destination;
an unexpected matching directory or symbolic link is preserved and makes the
fresh open fail closed. Therefore
a later resume with the displaced transfer ID fails `NOT_FOUND` instead of
reusing another upload's bytes. Names ending in `.droidmatch-upload-part` inside
the exposed root remain a legacy-reserved namespace: Android excludes them from
listings and rejects direct logical paths so interrupted pre-migration partials
do not become public after upgrade. New fresh uploads never delete those legacy
entries; new App Sandbox destinations using that reserved shape are rejected.

Fresh upload into a writable SAF directory appends a display-name segment to the
directory path. The root form is `dm://saf-<stable-id>/<display-name>`; a listed
directory uses `dm://saf-<stable-id>/doc/<directory-token>/<display-name>`.
The display name is a single path segment and must not contain `/`. Resumable SAF
upload derives a hidden sibling document from the stable transfer ID. The hidden
name additionally binds the expected size. Offset zero replaces any stale partial
for that exact identity; a non-final
close retains the new partial. A non-zero open requires the same tuple and an existing partial at
least as long as the Mac's last durable acknowledgement. If the partial is ahead,
Android must truncate it to that acknowledged offset before replay; a provider
without a seekable writable descriptor returns `ERROR_CODE_UNSUPPORTED_CAPABILITY`
instead of appending duplicate bytes. A shorter partial is rejected. The final
chunk renames the hidden document to the requested display name. Hidden names,
document IDs, and provider URIs remain Android-internal state.

Permanent cleanup accepts only the exact `(destination path, transfer ID,
expected size)` tuple persisted by the Mac before the first remote open. Android
takes the same destination lease used by writers, deletes only the matching
regular App Sandbox staging file or matching hidden SAF document, treats absence
as success, and never deletes the final destination. A tuple with the wrong size
derives a different private name. Fresh-only MediaStore rows are outside this
cleanup API.

## Android Provider Mapping

Android providers own the mapping from logical paths to platform APIs:

- Media roots map to MediaStore collections and stable media IDs where possible.
- SAF roots map to persisted tree URI permissions on Android.
- App-private roots map to app-owned storage; M1 exposes `dm://app-sandbox/` from the Android app's `files/droidmatch-sandbox` directory.
- App-sandbox relative paths are validated lexically before filesystem
  canonicalization: exact `.` / `..` segments, empty interior segments, and any
  existing symbolic-link component are rejected. Dot-prefixed names such as
  `.hidden` and `..backup` remain ordinary names.
- Optional non-Play legacy roots may map to direct File API access on API 26-29.

The Mac side must not infer Android access method from `root-id`. It must use
`FileEntry.can_read` and `FileEntry.can_write` independently, together with
negotiated capabilities and permission diagnostics. A false `can_read` blocks
navigation/preview/thumbnail work; it does not erase a true `can_write` upload
capability.

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
retains the exact local and remote paths, while a row item receives only a bounded,
spoofing-safe projection of the local basename. That safe value is also the only
filename allowed into opt-in system notifications. The unused remote logical path
and raw Core failure text are not copied into row state because they may contain
user names or an absolute path that Presentation does not need. Queue actions use
the stable job UUID rather than any displayed name.

Mac download destinations also reserve their local coordination infrastructure.
The final target and each of its six derived recovery names must not equal
`.droidmatch-download-locks`, `.droidmatch-download-lock-root`, or
`.droidmatch-private-atomic-lock` under the volume's name semantics; a destination
anywhere below a `.droidmatch-download-locks` ancestor is rejected before a lease
is acquired. These names are local-only and never become Android provider paths.

The current product uploader appends one local basename only to an authenticated,
writable app-sandbox, MediaStore-root, SAF-root, or opaque SAF-directory path.
Names containing `/`, `%`, control or Unicode format characters, `.` or `..` are
rejected before queue submission. Percent-bearing names remain
unsupported until both platforms share one segment decoder; sending an apparently
encoded path that Android treats as a literal display name would violate canonical
path identity. MediaStore destinations are fresh-only and are never replayed by
the product retry policy.

## Listing and Mutation Semantics

- `ListDirRequest.path` must be a logical directory path.
- `FileEntry.path` must be a canonical logical path returned by the provider.
- `FileEntry.duration_millis` is optional descriptive metadata, not identity or
  authorization. Only a MediaStore video file with canonical `video/*` MIME may
  carry a positive millisecond value; zero, negative, non-file, image/album,
  SAF, App Sandbox, and misclassified values are treated as unknown.
- App-sandbox listings omit symbolic links because M1 has no wire kind for them;
  directly addressing a symbolic-link component is invalid, while recursive
  deletion of an otherwise real directory unlinks a link child without
  traversing its target.
- `CreateDirectoryRequest.path` creates one logical directory.
- `DeletePathRequest.path` deletes one logical path; recursive deletion is allowed only when `recursive = true`.
- `RenamePathRequest.source_path` and `destination_path` must belong to the same
  provider root and the same real parent directory in M1. SAF document tokens
  bind the root and parent that produced the listing; missing or different
  parent provenance is rejected before the platform name-only rename call.

Cross-root and cross-directory moves are out of scope for M1. The Mac app should
implement those as copy plus delete only after transfer and mutation behavior is
proven.

## Page Tokens

`page_token` is opaque and provider-owned.

- Empty token starts a new listing.
- Tokens may encode provider root, query, sort order, permission snapshot, and cursor position.
- Tokens must not expose raw SAF URIs, filesystem paths, or personal file names in logs.
- A token is valid only for the exact `path`, `page_size`, `search_query`,
  `sort_field`, and `descending` values that produced it.
- Permission changes, root revocation, mutations under the listed directory, or provider restart may invalidate tokens.
- Invalid tokens return `ERROR_CODE_INVALID_ARGUMENT` with a user-safe message and a diagnostic detail.
- Mac clients must treat tokens as opaque bytes-in-a-string: do not parse, log, normalize, or synthesize them. The exact query tuple that produced a token must be reused.

M1 providers cap `page_size` to 1,000 entries. If a request uses
`page_size = 0`, the provider chooses a default of 200 entries. Android exact
query tokens cannot address a window past 10,000 entries; forged high offsets,
negative values, and overflow return `ERROR_CODE_INVALID_ARGUMENT`. If a
provider proves that more rows remain at the last admissible page, it returns an
error-only `ERROR_CODE_UNSUPPORTED_CAPABILITY` response instead of an empty next
token that would silently claim completeness. App Sandbox and SAF separately cap one
request at 25,000 inspected provider rows (including search-filtered rows) and
return `ERROR_CODE_UNSUPPORTED_CAPABILITY` when exact evaluation would exceed
that bound. They retain at most the leading `offset + page_size` candidates;
MediaStore continues pushing filter/sort/limit/offset into its provider query.

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
