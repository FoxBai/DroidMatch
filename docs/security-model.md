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
- P-256/SAS first pairing now includes a stable Keystore-backed Android identity signature, a default-closed visible Android window, ordered start/confirm/finalize dispatch, one-shot async Mac orchestration, provisional Keychain rollback, and bounded process-local exponential backoff. Per-ID and global reconnect buckets prevent random-ID rotation while preserving one generic failure shape. The Android product entry starts a paired-required endpoint; the debug harness alone explicitly retains correlation-only mode for archived M1 evidence. The Mac product session owns anonymous forward leases, credential selection, visible SAS approval, paired proof, and deterministic teardown. Real-device Keychain/Keystore/reconnect evidence remains open.
- Android exposes only display name and last-used time for paired Macs. Revoking one record removes its encrypted credential and stops the foreground USB service, terminating existing sessions before the endpoint can be enabled again.
- Pairing credentials must not travel in command-line arguments, diagnostics, support bundles, or ordinary logs. Revocation and re-pairing are part of the design, not recovery afterthoughts.
- ADB authorization remains useful transport evidence, but it does not identify which localhost process opened the forwarded socket.

The accepted protocol and UX direction is specified in [Pairing and Session Authentication Design](pairing-auth-design.md).

## ADB Forward Port Safety

- Bind forwarded services to localhost only.
- Allocate dynamic ports and record them in diagnostics.
- Reject non-DroidMatch traffic with `ERROR_CODE_PROTOCOL_ERROR`.
- Close the service endpoint when the foreground service stops or transport teardown begins.
- Do not kill the user's adb-server as routine recovery.

M1 does not require TLS over ADB forward. Strong pairing or an authenticated encrypted channel remains required before the product grants destructive capabilities to a merely local socket.

## Android-Side Authorization

- Transport availability does not grant file permissions.
- Providers must authorize each operation against live Android permission state.
- SAF roots must require persisted URI permission.
- Package visibility and APK operations must be capability-gated by build channel and Android policy.
- Silent install and silent uninstall remain out of scope.

## Logging and Support Bundles

Logs should be useful without leaking avoidable personal data.

- Redact Android device serial numbers by default.
- Redact access tokens, signing material, environment variables, and absolute Mac home paths.
- Prefer logical root IDs and file extensions over full personal file names in high-volume logs.
- Include full paths only in explicit debug logs or user-approved support bundles.
- Mac upload wire metadata uses `mac-local-upload` instead of a POSIX path or
  personal file name; local sidecars retain the real path without exposing it to
  Android. Normal harness success output uses explicit local-artifact placeholders.
- Native transfer-row state exposes only the local basename and an optional
  remote path that passed a `dm://` scheme check. It omits Core's raw failure
  description because local file/sidecar errors may legitimately contain an
  absolute POSIX path needed for debugging.
- Never include raw file contents in diagnostics.
- Support bundles must mark whether paths were redacted.
- Android cloud backup and device transfer exclude all DroidMatch private storage domains; pairing and authorization state must be recreated, not restored onto another device.

## Legacy Research Boundary

Security rules do not loosen for HandShaker compatibility research. Legacy notes may describe observed behavior, but must not include old binaries, keys, credentials, private endpoints, or copied implementation details.

## Open Security Work for M1

M1 should produce evidence for:

- Validate real Keychain/Keystore invalidation, add user-facing revocation, and archive real-device pairing/reconnect and rate-limit evidence before destructive product capabilities ship.
- Whether AOA requires payload CRC on all frames for observed device stability.
- Which diagnostics fields are too sensitive to include by default.
- Whether non-Play enhanced storage modes need an explicit user-visible risk warning.
