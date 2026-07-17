# Security Model

DroidMatch is local-first and USB-first, but local USB does not mean trust everything. M1 should keep the trust boundary explicit even before product UI polish.

## Trust Boundaries

- The Mac app and Android service are both DroidMatch-controlled code.
- ADB authorization proves that the user allowed this Mac to talk to the device through Android's debugging channel.
- ADB forward exposes a localhost port on the Mac. Other local Mac processes may attempt to connect.
- AOA exposes a USB accessory channel. It must not imply file or media permissions.
- Support bundles may contain sensitive file names, paths, device metadata, and timing information.

## M1 Session Correlation

M1 uses the nonce fields as a lightweight freshness and response-correlation challenge before accepting control-plane requests after handshake:

- Mac generates a fresh cryptographically secure 32-byte value for each TCP handshake and sends it in `ClientHello.session_nonce`.
- Android rejects nonce lengths outside 16 to 32 bytes and echoes the accepted value in `ServerHello.session_nonce`.
- Mac requires the ServerHello nonce to be 16 to 32 bytes and exactly match its ClientHello value.
- Android binds accepted requests to the active transport endpoint and negotiated session.
- Requests received before handshake completion are rejected with `ERROR_CODE_UNAUTHORIZED`, provisional state is zeroized, and that socket closes; setup errors cannot be replayed into a later valid Hello.
- Diagnostics may record only nonce length or validation state, never the nonce bytes.

This detects stale or mis-correlated ServerHello frames and accidental cross-session reuse. It is **not identity authentication**: another local process can generate its own nonce and open its own handshake. Calling nonce echo "authentication" would overstate the guarantee.

The optional envelope-payload CRC detects accidental corruption of serialized `payload` bytes only; it does not cover envelope metadata or the separate top-level `error` field. The mandatory transfer-chunk CRC covers chunk data. Neither checksum authenticates a peer or prevents deliberate tampering. A flagged payload mismatch is rejected before nested payload parsing. During setup it closes the unauthenticated session; in ready state, Android transfer-scoped protocol/integrity failures release the correlated provider handle, stream slot, and destination lease immediately instead of depending on a later socket close, while a bounded ID-only marker drains the already-negotiated tail without retaining file access. Unrelated ready-state routes remain isolated by the open request/stream identity pair.

## Product Authentication Boundary

- A bearer token passed through a debug Activity extra and repeated in ClientHello would only protect against clients that cannot observe or invoke that ADB setup path. Same-user local malware may inspect process activity or use the authorized adb server, so this is not a product-grade trust boundary.
- The wire now supports a paired reconnection mode: ClientHello carries a pairing ID and fresh client nonce; ServerHello supplies a fresh server nonce and stable device-identity fingerprint; role-separated HMAC proofs authenticate both peers over a canonical transcript. The fingerprint is only a local credential selector and remains untrusted until proof succeeds. Android does not enter `READY` or grant capabilities until the client proof succeeds, and the Mac rejects a missing/invalid server proof, identity mismatch, or downgrade to correlation-only mode.
- Unknown pairing IDs follow the same challenge/proof shape using an ephemeral fake key, then return the same generic unauthorized result as a bad proof. Authentication failure and out-of-order authentication traffic close the transport.
- P-256/SAS first pairing now includes a stable Keystore-backed Android identity signature, a default-closed visible Android window, ordered start/confirm/finalize dispatch, one-shot async Mac orchestration, provisional Keychain rollback, and bounded process-local exponential backoff. Per-ID and global reconnect buckets prevent random-ID rotation while preserving one generic failure shape. The Android product entry starts a paired-required endpoint; the debug harness alone explicitly retains correlation-only mode for archived M1 evidence. The Mac product session owns anonymous forward leases, credential selection, visible SAS approval, paired proof, and deterministic teardown. Slot C archives real product Keychain reconnect plus attended Android Keystore identity/wrapping-key behavior.
- Mac trusted-device display validates a versioned key-free `kSecAttrGeneric`
  envelope or, for a pre-envelope record, its account/label/Keychain dates;
  ordinary App launch and dashboard refresh never request password data.
  Credential selection is a separate explicit-connection operation. Current
  records load only the fingerprint match; bounded legacy account reads share one
  `LAContext` and backfill all validated selectors. Malformed or mismatched
  metadata fails closed. After paired proof, the Core coordinator transfers that
  already-validated credential into the same-generation invalidatable retry gate
  instead of rereading Keychain for scheduler construction, then clears its own
  reference. It never enters Presentation, diagnostics, logs, or persistence, and
  disconnect/replacement/keepalive failure releases it through the audited gate
  teardown.
  First pairing similarly keeps the freshly persisted record inside Core for the
  immediate proof instead of reading the new item back. Its provisional publish
  is atomic and add-only: every duplicate pairing ID fails without reading or
  updating the existing item. A successful reconnect
  never rewrites the secret-bearing item merely to record recency.
- Android exposes only display name and last-used time for paired Macs. Revoking one record removes its encrypted credential and stops the foreground USB service, terminating existing sessions before the endpoint can be enabled again. If encrypted-record deletion fails, the UI reports the failure but still requests service teardown so the failed storage mutation cannot leave an authenticated session running.
- Mac-supplied names are authenticated raw metadata, not trusted presentation text. Before the Android pairing approval, paired-Mac list, or revoke confirmation renders one, a UI-only projection NFC-normalizes it, collapses whitespace, removes control/Unicode-format/surrogate code points, and substitutes fixed `Mac` if no visible content remains. This cannot change the pairing transcript, credential record, SAS, or pairing-ID revoke target; it prevents newline, bidirectional-format, and zero-width UI spoofing without retargeting a security action.
- Android applies the same projection to provider-controlled SAF folder names in its grant list and destructive release confirmation, using a localized unnamed-folder fallback. Final text is capped at 120 Unicode code points; a real visible truncation reserves the last code point for an ellipsis. The release action still targets the original stable root and persisted tree grant; display cleanup cannot select a different authorization.
- Mac applies one bounded `ProductDisplayText` projection to platform- or peer-controlled ADB model/product, pairing, trusted-device, ready-session, diagnostics, and remote-entry labels before publishing them to product state. Its default cap is 120 Unicode scalars, remote entries use 240, and real truncation is visibly marked within the cap. Stable anonymous device IDs, pairing records, and logical paths remain separate action identities. The Published pairing decision contains only that safe Android label and the six-digit SAS; the Core device-identity fingerprint never enters Presentation.
- Retail-name enrichment is a display-only boundary. The resolver never receives an ADB serial, pairing identity, path, or credential and never constructs a per-device web query; an unresolved tuple requests one exact Google Play full-catalog URL through an ephemeral session with cookies/cache disabled, redirects rejected, `identity` content encoding requested, final response URL/status checked, and bytes streamed into an 8 MiB accumulator that cancels acceptance at the next byte. Accepted data must be non-empty UTF-16LE CSV with the exact four-column header and stay within 200,000 rows/512 scalars per field. Matching and cache identity use non-truncating, NFC-normalized identifiers capped at 512 scalars; distinct raw marketing names remain ambiguous even if their 120-scalar UI projections would coincide. A dedicated catalog-loader actor builds the bounded process-local index, while the resolver actor keeps at most 64 pending queries and 512 safe names persisted under lowercase SHA-256 tuple keys; raw tuple values and the full catalog are not stored. The known 704SH mapping is available offline, and every failure degrades to the already-sanitized technical name.
- A valid paired reconnect monotonically updates that record's encrypted
  last-used timestamp. Failure to persist recency is reported only as a bounded
  diagnostic state and does not turn an already verified proof into an
  authentication failure; keys, pairing IDs, and storage exceptions remain
  outside UI/wire diagnostics.
- Pairing credentials must not travel in command-line arguments, diagnostics, support bundles, or ordinary logs. Revocation and re-pairing are part of the design, not recovery afterthoughts.
- ADB authorization remains useful transport evidence, but it does not identify which localhost process opened the forwarded socket.

The accepted protocol and UX direction is specified in [Pairing and Session Authentication Design](pairing-auth-design.md).

## ADB Forward Port Safety

- Bind forwarded services to localhost only.
- Allocate dynamic ports and record them in diagnostics.
- Reject non-DroidMatch traffic with `ERROR_CODE_PROTOCOL_ERROR`.
- Bound the Android endpoint to four queued/running sessions. A peer beyond that
  resource boundary is closed before ClientHello, so no typed wire error is promised.
- Close every rejected setup exchange after its bounded response and zeroization;
  invalid frames must not refresh the handshake window or reserve a slot indefinitely.
- Linearize listener publication, client admission, and endpoint teardown under
  one lifecycle lock. Once teardown wins that boundary, no later listener
  publication or client admission can succeed, and the listener plus every
  already-admitted socket is closed. Workers admitted before that boundary unwind
  against the closed socket; shutdown does not promise to join their completion.
- Do not kill the user's adb-server as routine recovery.

This admission bound limits Android worker/socket ownership; it does not claim to
eliminate the kernel listen backlog or every denial-of-service attempt by another
local process.

M1 does not require TLS over ADB forward. Strong pairing or an authenticated encrypted channel remains required before the product grants destructive capabilities to a merely local socket.

## Android-Side Authorization

- Transport availability does not grant file permissions.
- Providers must authorize each operation against live Android permission state.
- SAF roots must require persisted URI permission.
- The Android product grant UI treats a fresh persisted-permission list as the
  add/revoke commit boundary. A selected root must appear after picker return
  and disappear after release; platform exceptions, missing snapshots, malformed
  entries, or a still-present root fail closed with fixed guidance. Tree URIs
  and platform exceptions remain outside UI, logs, and wire errors.
- MediaStore downloads re-check the image/video-specific read state before every
  provider chunk. Full access needs no extra provider query; Android 14+
  selected-media access also re-queries the exact item URI so retaining a global
  partial-access bit cannot keep a deselected item readable through an old
  descriptor. SAF downloads re-check their exact persisted tree read grant;
  SAF uploads re-check exact tree read/write before every chunk and again after
  final bytes are written but before flush/close/rename. When the endpoint
  survives long enough to observe a
  revoked grant, it closes the provider handle and fails the correlated route
  with `permissionRequired`; Android may instead terminate the endpoint during
  a runtime-permission change, in which case Mac observes transport loss.
  Open-time admission is never treated as a transfer-lifetime capability.
- App-sandbox paths reject lexical root aliases and every existing symbolic-link
  component before canonicalization. Recursive deletion of an otherwise real
  directory treats a symbolic-link child as one leaf entry; it must never
  enumerate or delete through the link target. Symbolic-link entries are
  excluded from listings because M1 cannot represent them safely.
- App-sandbox upload keeps the existing destination until a final
  same-filesystem atomic replacement succeeds. Unsupported atomic replacement
  fails before final ACK and must not fall back to a non-atomic overwrite.
- App-sandbox final commit must force the same no-follow partial channel before
  closing and atomically replacing the destination. A synchronization failure
  is a failed transfer, not a successful final ACK; the prior destination and
  resumable partial remain available for recovery.
- App-sandbox upload partials must stay outside the exposed logical root in a
  no-follow private staging directory. The opaque staging identity binds the
  logical destination, stable transfer ID, and expected size; a different fresh
  transfer invalidates the older identity rather than reusing its bytes. Resume
  binds length validation, truncation, and append to one descriptor. The staging
  node itself must be a no-follow directory; an ordinary file or symbolic link is
  rejected without deletion, traversal, target access, or destination publication.
  Fresh cleanup deletes only matching regular partials; a matching directory or
  symbolic link is preserved and fails closed. A partial symlink must fail before
  any target bytes are changed.
- Permanent resumable-upload cleanup is a paired-authenticated mutation, not a
  side effect of transport cancellation. Mac must durably bind the destination,
  transfer ID, and expected size before the first remote open; Android requires
  `FILE_WRITE` plus `RESUMABLE_TRANSFER`, takes the same exact destination lease
  as an upload writer, and derives only the private App Sandbox/SAF partial name.
  Missing is idempotent success. Cleanup must never resolve to or delete the
  visible final destination, and a failed cleanup must remain durable/retryable
  rather than being hidden by cancellation, history removal, or shutdown.
- The former in-root `.droidmatch-upload-part` namespace remains hidden and
  unaddressable after migration. Fresh uploads neither reuse nor delete those
  legacy remnants, and new App Sandbox destinations cannot claim the reserved
  shape, preventing incomplete pre-upgrade bytes from becoming public files.
- App-sandbox download fingerprints must obtain size, mtime, and replacement
  identity from the already-open descriptor. Device/inode/ctime values are
  hashed into an opaque provider etag and never appear on the wire or in logs.
- Package visibility and APK operations must be capability-gated by build channel and Android policy.
- Silent install and silent uninstall remain out of scope.

## Logging and Support Bundles

Logs should be useful without leaking avoidable personal data.

- Redact Android device serial numbers by default.
- Mac harness device-facing output (including `devices` and `forward`) uses a stable SHA-256 display tag; raw ADB serials are accepted only as explicit operator input for a selected test target.
- `tools/run-m1-device-smoke.sh` routes captured output, validation failures, terminal summaries, and staged result logs through `tools/m1-output-redaction.sh`; local paths, logical remote paths, test names, notes, and serials are replaced with bounded labels before publication. Raw values remain process-local only for the requested operation.
- Redact access tokens, signing material, environment variables, and absolute Mac home paths.
- Prefer logical root IDs and file extensions over full personal file names in high-volume logs.
- Android endpoint and RPC session lifecycle logs and structured diagnostics record only a stable operation label and exception class; they never pass a `Throwable` message or EOF text to Logcat or a state event, because provider messages, transport text, and stack traces can contain private paths, content URIs, document IDs, or user file names. Provider wire errors use provider-owned bounded labels and never echo caller-supplied paths; the diagnostics ring keeps the same bounded label shape instead of depending on an incomplete redaction regex.
- `tools/check-maintainer-contract.py` enforces this boundary for endpoint/RPC warning and error Logcat calls, so a future catch block cannot silently reintroduce a raw exception argument. 中文：维护者门禁会检查 endpoint/RPC 的 warning/error Logcat 调用，防止后续 catch 块悄悄重新透传异常原文。
- The Mac `Network.framework` session maps callback failures to the fixed
  `network failure` label; it never stores `localizedDescription` in a
  `FramedTcpClientError`. The maintainer contract checks this source boundary
  so OS-controlled endpoint text cannot leak through retry or harness output.
  中文：Mac 的 `Network.framework` 会把回调异常映射为固定的
  `network failure` 标签，不把 `localizedDescription` 写入
  `FramedTcpClientError`；维护者门禁会锁住这条边界，防止系统端点文本经重试或
  harness 输出泄露。
- Directory-listing, mutation, thumbnail, and transfer assembly applies the same
  boundary to catalog failures from MediaStore, the app sandbox, and SAF. Detailed
  `ProviderCatalogException` messages remain local implementation evidence; every
  wire response contains only the stable error code plus a provider- or operation-
  owned bounded label.
  中文：MediaStore、App Sandbox 与 SAF 的目录、mutation、缩略图和传输异常不得把 provider 原文带上 wire。
- Include full paths only in explicit debug logs or user-approved support bundles.
- Mac upload wire metadata uses `mac-local-upload` instead of a POSIX path or
  personal file name; local sidecars retain the real path without exposing it to
  Android. Normal harness success output uses explicit local-artifact placeholders.
- MediaStore upload filename admission is duplicated at the Mac product boundary
  and Android provider boundary. Names containing control or Unicode format
  characters are rejected, and unknown or cross-category extensions fail before
  row creation with a fixed label that does not echo the display name. Android
  never falls back from an unrecognized or cross-category filename to a default
  JPEG/MP4 declaration. Accepted payload bytes are not decoded in M1, so this
  filename-declaration check is not content validation.
- Direct Mac harness diagnostics also replace remote paths, entry names, provider
  messages, and exception descriptions with bounded labels before writing stdout
  or stderr; the device smoke script may add only its documented redacted evidence.
- Native transfer-row state exposes only a bounded `ProductDisplayText` projection
  of the local basename; the same safe value feeds opt-in system notifications.
  Remote logical paths and Core's raw failure description remain below Presentation
  because they may contain user names or absolute POSIX paths needed for operation
  and debugging. Pause/resume/cancel/remove continue to target the stable job UUID.
- The transfer scheduler also applies the privacy boundary before publishing a
  retry or terminal outcome: known failures become stable categories and remote
  failures retain only their protocol error code. Provider messages, document
  IDs, and local exception text do not cross the scheduler snapshot boundary.
- The native file-browser header preserves a user-readable location title in
  navigation history instead of rendering logical paths. Opaque SAF and album
  tokens remain internal identity/authorization values even though they are not
  secrets on the wire.
- Remote names have a separate bounded display representation: NFC-normalized,
  stripped of control, bidi override/isolate, and selected invisible format
  scalars, then capped at 240 characters. Raw names and canonical logical paths
  remain the operation identity; sanitizing visible text must never retarget a
  delete, transfer, selection, or provider request.
- Provider MIME is optional descriptive metadata, not an authorization or
  capability signal. The Mac product domain accepts only a restricted ASCII
  type/subtype of at most 127 bytes plus two product-owned virtual labels,
  canonicalizes it to lowercase, and maps control-bearing, non-ASCII, parameterized,
  malformed, or oversized input to nil without suppressing the directory row.
- Never include raw file contents in diagnostics.
- Support bundles must mark whether paths were redacted.
- The current Mac product export is a schema-v1 JSON diagnostics report, not a
  raw log archive. Its encoder has an explicit allowlist and no representable
  fields for serials, pairing IDs, fingerprints, ports, file names/paths,
  credentials, raw errors, or raw logs; paths are therefore omitted rather than
  replaced with reversible placeholders. Its environment section is restricted
  to bounded product/build/macOS version strings and fresh/stale state; it does
  not include host name, user name, hardware UUID, locale, or process paths. The
  encoder also revalidates a separately constructed public snapshot: device text
  is bounded/control-safe, invalid SDK/storage/battery values are omitted, recent
  errors stay within 0–100, and negative counters are discarded.
- Android cloud backup and device transfer exclude all DroidMatch private storage domains; pairing and authorization state must be recreated, not restored onto another device.

## Local Recovery Data

- A download reserves seven related names as one namespace: final, partial,
  sidecar, sidecar `.pending`/`.removing`, fixed `.droidmatch-commit`, and
  fixed `.droidmatch-replaced`. Any lexical intersection is rejected inside a
  scheduler. Product execution also holds an in-process reservation keyed by
  the pinned parent device/inode and volume case semantics plus sorted
  cross-process advisory locks for the same entry set, together with the
  security-scope lease and directory FD. The fixed parent-relative `0700`
  `.droidmatch-download-locks` root, `0600`
  `.droidmatch-download-lock-root` anchor, and empty single-link `0600` hashed
  lock files are owner/type/inode checked and persist for safe reuse after
  release; a previously unseen destination may add at most seven zero-byte
  inodes. Fixed macOS `/var`,
  `/tmp`, and `/etc` aliases are mapped to `/private` before component-wise
  no-follow opening; other ancestor symlinks, unexpected directories, FIFOs, and
  hard links are retained and fail closed.
- The sibling `.droidmatch-part` must be a single-link regular file. The writer
  takes a non-blocking exclusive `flock`, rechecks that the locked descriptor
  still names the pinned child, and retains the lock through publication. Fresh
  open acquires without truncation; after safe sidecar removal, `resetFresh`
  truncates that same FD before any connection. Resume validates the pinned entry
  and opened descriptor before seek or write. `flock` is advisory, not a defense
  against a malicious same-UID process that ignores it.
- Final publication binds the initially observed destination snapshot and
  destination/partial identities. It first creates a fixed `0600` commit marker,
  synchronizes the file and directory, then uses `RENAME_EXCL` for an absent
  destination or validated `RENAME_SWAP` for an existing one. The displaced old
  destination moves to the fixed replaced entry and remains there until the
  coordinator has safely removed the resume sidecar. Finalization then unlinks
  the verified old entry, synchronizes the directory, and removes the marker.
  Failure or cancellation before finalization restores the old destination and
  moves the candidate back to partial while retaining the marker, republishes
  the sidecar, and removes the marker only after that checkpoint is durable. A
  failed checkpoint restore leaves the marker for interrupted recovery;
  inability to prove restoration returns
  non-retryable `commitUncertain`. Crash-left marker/replaced entries force
  `interrupted` restoration. A destination symlink is replaced as an entry, not
  followed. Required `fsync` narrows process-crash recovery but is not a complete
  power-loss durability guarantee. Hashed persistent lock names do not directly
  expose paths but remain guessable pseudonymous metadata, and a malicious
  same-UID process may ignore advisory locks and retain narrow checked-operation races.
- Download/upload sidecars, queue manifests, and security-scoped bookmark
  registries contain private Mac paths, source identity, or authorization
  material. Their exact reads pin the direct parent, open no-follow, enforce a
  bounded single-link private regular file, and recheck descriptor/entry identity
  after reading. They must never exist with group/other access.
- Queue manifest filenames use a domain-separated routing digest derived only
  after device authentication; this avoids placing the raw stable fingerprint
  in Application Support directory entries but is pseudonymization, not
  encryption. A legacy raw-fingerprint filename is renamed only when the new
  location is absent, using an atomic no-clobber operation. A collision,
  symbolic link, or non-regular node is retained and rejected without choosing
  or deleting either candidate.
- Sidecar and private queue/bookmark stores use fixed `.<name>.pending` and
  `.<name>.removing` recovery entries. Save creates `.pending` at `0600`, requires
  file `fsync`, then uses `RENAME_EXCL` for absence or `RENAME_SWAP` for replacement
  with complete-stat two-way validation. Remove renames the expected entry to
  `.removing`, revalidates it, then unlinks. Every mutation rechecks that the
  parent path still names the pinned directory and requires directory `fsync`;
  unlink/sync/publication failure must prove safe rollback or return
  `commitUncertain` while leaving a discoverable recovery entry. Each used pinned
  parent keeps one permanent zero-byte `0600` `.droidmatch-private-atomic-lock`.
  It is opened no-follow, must remain an euid-owned single-link regular file, and
  is matched back to its named inode after exclusive `flock`; read/save/remove in
  cooperating processes and separate same-process opens therefore serialize on
  one inode. Unsafe lock nodes and crash-left markers remain fail-closed evidence.
  Unexpected directories, symlinks, FIFOs,
  and hard links are preserved; ordinary cooperative races fail closed. A
  malicious same-UID process can still replace an entry in the narrow final
  full-stat-to-`unlinkat` window, so the advisory lock is not a malicious same-UID
  security boundary. The fixed lock contains no target name or path and costs one
  persistent inode per used parent; it is never unlinked because replacement would
  split callers across lock inodes. No permissive pre-chmod file becomes visible. These
  guarantees cover tested process interruption, not arbitrary power-loss durability.
- Resumable uploads use format-v2 source identity: size, nanosecond mtime,
  nanosecond ctime, filesystem number, and inode from one attempt-long
  `O_NOFOLLOW` descriptor. Every read revalidates both descriptor and current
  path. A non-zero v1 checkpoint is interrupted/rejected before any reconnect;
  a same-size, same-millisecond replacement cannot be spliced onto an older
  remote prefix.
- The schema-v2 queue separately persists the exact remote partial identity
  before the coordinator may connect. Cancellation is not terminal until remote
  disposal and local sidecar removal succeed. Failed/interrupted history keeps
  that identity until an authenticated cleanup precedes removal; AppSupport keeps
  the security-scoped source bookmark until the deferred row actually disappears.
- Queue restoration cannot compare that v2 identity with the live source until
  AppSupport holds its security-scoped bookmark lease. It therefore admits only
  structurally/path-valid, strictly incomplete (`offset < known total`) state to
  paused; after lease acquisition, the coordinator snapshots and compares the
  exact source before creating any client. Completed, zero-of-zero, unknown-total,
  conflicting-total, or stale-source state never opens a transfer automatically.
- A caller-owned existing parent directory keeps its mode; confidentiality must
  therefore come from the private file mode even when that directory is `0755`.
- Failed writes preserve the last durable state and expose only coarse health;
  raw filesystem errors and absolute recovery paths remain below the UI boundary.
- An unreadable or corrupt bookmark archive or queue manifest discovered at
  startup remains untouched. Authorization access, transfer submission, and
  executor replay fail closed until an explicit retry can reload, validate, and
  canonicalize repaired durable state; empty runtime fallbacks must never
  overwrite those archives.
- Product queue restoration keeps executor admission latched until the local
  access provider verifies every non-terminal endpoint against the durable
  bookmark registry. A structurally valid but empty or incomplete registry is
  not sufficient to activate queued work, and Resume cannot bypass this check.
- Only a completed authenticated proof may derive the domain-separated opaque
  bookmark owner. The owner remains below Presentation and normal diagnostics;
  the v2 archive uses it only to scope `(owner, endpoint)` records. Readiness,
  access, removal, and pruning for one owner cannot consume or delete another
  owner's scoped authority, even when both use the same local path.
- One AppSupport factory owns the archive actor and a process-wide FIFO gate.
  The gate serializes authority-set mutations and consistency transitions with
  the full held restoration transaction: manifest load, authoritative target
  projection, owner coverage, reconciliation, and activation. Normal transfer
  I/O does not hold this gate.
- Persistent scheduler construction is also generation-bound single-flight.
  Concurrent callers cannot restore the same manifest twice; disconnect cancels
  the in-flight build, invalidates its transfer gate, and suspends any scheduler
  registered before activation. Cleanup is build-ID scoped so an old generation
  cannot clear or overwrite a replacement session's resources.
- A scheduler returned to an older UI generation is permanently invalid after
  session suspension. It may finish teardown bookkeeping, but every later
  pause/resume/cancel/remove/persistence-retry/activation request is rejected,
  repeated suspension and shutdown are no-ops, and it no longer publishes an
  authoritative endpoint set. This prevents a delayed UI task or stale build
  cleanup from overwriting the replacement scheduler's manifest.
- Version-1 path-only records cannot be attributed safely. They migrate only to
  a separate legacy-unscoped compartment and remain an explicit compatibility
  fallback for any owner whose own scoped record is absent. A scoped record is
  authoritative even when resolution fails; failure must not fall back to
  legacy. Phase 1 never guesses ownership or deletes legacy records; cleanup
  requires a later complete, durable inventory of every device manifest.

## Apple Privacy Manifests

- The Mac App places its own `PrivacyInfo.xcprivacy` at
  `Contents/Resources/PrivacyInfo.xcprivacy`, the location documented for macOS
  Apps by [Apple](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk).
- DroidMatch declares no tracking, tracking domains, or developer/third-party
  data collection. Its USB file exchange remains local between the user's Mac
  and selected Android device.
- SwiftProtobuf's separate privacy manifest remains inside its dependency
  resource bundle; the custom App assembler must copy, not flatten, that bundle.
- Core uses file metadata and monotonic `systemUptime` for transfer integrity,
  retry timing, and rates. Apple's current
  [required-reason API scope](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
  names iOS, iPadOS, tvOS, visionOS, and watchOS rather than macOS, so the Mac
  declaration does not invent mobile-platform reason codes. Any future Catalyst
  or mobile target must perform a fresh API/reason audit.
- The bundle verifier parses both manifests and freezes the App declaration;
  changes to collection, tracking, or accessed-API claims require explicit review.
- The current custom Mac bundle is a static directory tree with no framework
  symlink layout. Before reading Info.plist, privacy declarations, notices,
  executables, or signatures, its verifier requires owner-readable/traversable
  real directories and owner-readable single-link regular files only. Symlinks,
  hard-linked files, FIFO/socket/device nodes, unreadable subtrees, special
  permission bits, and group/world-write access are rejected. A
  required resource or embedded adb therefore cannot be satisfied through an
  outside host alias or mutable shared inode. This is a static artifact boundary,
  not a claim of resistance to an actively racing malicious same-UID process.

## Legacy Research Boundary

Security rules do not loosen for HandShaker compatibility research. Legacy notes may describe observed behavior, but must not include old binaries, keys, credentials, private endpoints, or copied implementation details.

## Open Security Work for M1

M1 should produce evidence for:

- Extend real-device credential-invalidation and rate-limit evidence beyond the archived Slot C pairing/reconnect, attended Keystore, and trust-revocation runs. Destructive product capabilities are already gated by paired proof plus per-request capability checks; Mac disconnects before Keychain deletion, rejects pre-revoke list results that arrive late, and retains the trusted row with fixed privacy-bounded guidance when deletion cannot be confirmed. Android closes active USB sessions.
- Whether AOA requires payload CRC on all frames for observed device stability.
- Which diagnostics fields are too sensitive to include by default.
- Whether non-Play enhanced storage modes need an explicit user-visible risk warning.
