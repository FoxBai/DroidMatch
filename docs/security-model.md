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
- Requests received before handshake completion are rejected with `ERROR_CODE_UNAUTHORIZED`.
- Diagnostics may record only nonce length or validation state, never the nonce bytes.

This detects stale or mis-correlated ServerHello frames and accidental cross-session reuse. It is **not identity authentication**: another local process can generate its own nonce and open its own handshake. Calling nonce echo "authentication" would overstate the guarantee.

## Product Authentication Boundary

- A bearer token passed through a debug Activity extra and repeated in ClientHello would only protect against clients that cannot observe or invoke that ADB setup path. Same-user local malware may inspect process activity or use the authorized adb server, so this is not a product-grade trust boundary.
- The wire now supports a paired reconnection mode: ClientHello carries a pairing ID and fresh client nonce; ServerHello supplies a fresh server nonce and stable device-identity fingerprint; role-separated HMAC proofs authenticate both peers over a canonical transcript. The fingerprint is only a local credential selector and remains untrusted until proof succeeds. Android does not enter `READY` or grant capabilities until the client proof succeeds, and the Mac rejects a missing/invalid server proof, identity mismatch, or downgrade to correlation-only mode.
- Unknown pairing IDs follow the same challenge/proof shape using an ephemeral fake key, then return the same generic unauthorized result as a bad proof. Authentication failure and out-of-order authentication traffic close the transport.
- P-256/SAS first pairing now includes a stable Keystore-backed Android identity signature, a default-closed visible Android window, ordered start/confirm/finalize dispatch, one-shot async Mac orchestration, provisional Keychain rollback, and bounded process-local exponential backoff. Per-ID and global reconnect buckets prevent random-ID rotation while preserving one generic failure shape. The Android product entry starts a paired-required endpoint; the debug harness alone explicitly retains correlation-only mode for archived M1 evidence. The Mac product session owns anonymous forward leases, credential selection, visible SAS approval, paired proof, and deterministic teardown. Slot C archives real product Keychain reconnect plus attended Android Keystore identity/wrapping-key behavior.
- Android exposes only display name and last-used time for paired Macs. Revoking one record removes its encrypted credential and stops the foreground USB service, terminating existing sessions before the endpoint can be enabled again.
- Pairing credentials must not travel in command-line arguments, diagnostics, support bundles, or ordinary logs. Revocation and re-pairing are part of the design, not recovery afterthoughts.
- ADB authorization remains useful transport evidence, but it does not identify which localhost process opened the forwarded socket.

The accepted protocol and UX direction is specified in [Pairing and Session Authentication Design](pairing-auth-design.md).

## ADB Forward Port Safety

- Bind forwarded services to localhost only.
- Allocate dynamic ports and record them in diagnostics.
- Reject non-DroidMatch traffic with `ERROR_CODE_PROTOCOL_ERROR`.
- Bound the Android endpoint to four queued/running sessions. A peer beyond that
  resource boundary is closed before ClientHello, so no typed wire error is promised.
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
- App-sandbox upload keeps the existing destination until a final
  same-filesystem atomic replacement succeeds. Unsupported atomic replacement
  fails before final ACK and must not fall back to a non-atomic overwrite.
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
- Direct Mac harness diagnostics also replace remote paths, entry names, provider
  messages, and exception descriptions with bounded labels before writing stdout
  or stderr; the device smoke script may add only its documented redacted evidence.
- Native transfer-row state exposes only the local basename and an optional
  remote path that passed a `dm://` scheme check. It omits Core's raw failure
  description because local file/sidecar errors may legitimately contain an
  absolute POSIX path needed for debugging.
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
- Never include raw file contents in diagnostics.
- Support bundles must mark whether paths were redacted.
- The current Mac product export is a schema-v1 JSON diagnostics report, not a
  raw log archive. Its encoder has an explicit allowlist and no representable
  fields for serials, pairing IDs, fingerprints, ports, file names/paths,
  credentials, raw errors, or raw logs; paths are therefore omitted rather than
  replaced with reversible placeholders. Its environment section is restricted
  to bounded product/build/macOS version strings and fresh/stale state; it does
  not include host name, user name, hardware UUID, locale, or process paths.
- Android cloud backup and device transfer exclude all DroidMatch private storage domains; pairing and authorization state must be recreated, not restored onto another device.

## Local Recovery Data

- Download payloads pin the user-authorized destination directory for the
  writer lifetime. The sibling `.droidmatch-part` is opened without following
  a terminal symbolic link and must be a regular file; final same-directory
  rename replaces a destination symlink entry instead of writing through it.
- Queue manifests and security-scoped bookmark registries contain private Mac
  paths or authorization material and must never exist with group/other access.
- Both stores create an unpredictable same-directory candidate at `0600` before
  writing any bytes, synchronize it, reject symbolic-link destinations, and
  atomically replace the durable file. They do not rely on chmod after a
  permissive file has already become visible.
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

## Legacy Research Boundary

Security rules do not loosen for HandShaker compatibility research. Legacy notes may describe observed behavior, but must not include old binaries, keys, credentials, private endpoints, or copied implementation details.

## Open Security Work for M1

M1 should produce evidence for:

- Extend real-device credential-invalidation and rate-limit evidence beyond the archived Slot C pairing/reconnect, attended Keystore, and trust-revocation runs. Destructive product capabilities are already gated by paired proof plus per-request capability checks; Mac disconnects before Keychain deletion and Android closes active USB sessions.
- Whether AOA requires payload CRC on all frames for observed device stability.
- Which diagnostics fields are too sensitive to include by default.
- Whether non-Play enhanced storage modes need an explicit user-visible risk warning.
