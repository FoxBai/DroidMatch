# Pairing and Session Authentication Design

Status: accepted engineering direction as of 2026-07-11. Reconnection auth is
wired and tested. First-pairing protobuf, P-256/ECDH, stable Android identity
signatures, canonical derivation, three-phase confirmations, the visible Android
pairing window, Android dispatcher, async Mac client, macOS Keychain storage, and
Android Keystore-wrapped storage are implemented and covered by local tests. The
Mac product approval UI, trust revocation UI, and paired-required Android product
endpoint are wired. Slot C ordinary and sandbox product pairing/reconnect,
authenticated browsing, and transfer evidence are archived. The isolated
Android Keystore instrumentation runner also passes on Slot C MEIZU M20 after
the user manually approves the OEM test-APK installation prompt; this is not an
unattended-install claim. Developer ID signing and notarization remain deferred
release work.

## Security Goal

DroidMatch must distinguish the paired Mac app from another process that merely
discovers and connects to the localhost ADB-forward port. Before file mutation,
package operations, or other destructive capabilities are granted, both endpoints
must prove possession of a user-approved per-device pairing key with fresh
connection nonces.

The design must:

- work on macOS 13+ and Android API 26+;
- avoid passwords, account services, and cloud dependencies;
- resist replay of a previously captured authenticated handshake;
- require visible user confirmation for first pairing;
- keep pairing secrets out of protobuf logs, command lines, diagnostics, and
  support bundles;
- support revocation and re-pairing without reinstalling either app;
- keep the current nonce-only M1 harness usable with a strictly reduced,
  unauthenticated capability set during migration.

## Threat Boundary

In scope:

- another unprivileged process on the Mac connects to the forwarded localhost port;
- a stale or captured ClientHello, ServerHello, or authentication proof is replayed;
- an unpaired client races the legitimate app during pairing or reconnection;
- logs, crash reports, and support bundles are inspected after the fact;
- a pairing is revoked on either side but the peer attempts to reuse old material.

Out of scope for this layer:

- root/admin compromise of macOS or a rooted Android device;
- malicious UI overlays that defeat the user's comparison of both displayed codes;
- traffic confidentiality. ADB already supplies a local USB transport; a later TLS
  or record-AEAD decision can add confidentiality without redefining pairing.

The protocol should still fail closed under out-of-scope attacks where practical.
Denial of service against a localhost port is not prevented by authentication.

## Cryptographic Suite

Use platform primitives available on the minimum OS versions:

| Purpose | Primitive |
|---|---|
| First-pairing key agreement | ECDH P-256 (`secp256r1`) |
| Android device identity | ECDSA P-256 (`SHA256withECDSA`) |
| Transcript hash | SHA-256 |
| Key derivation | HKDF-SHA-256 |
| Session proofs | HMAC-SHA-256 |
| Random nonces | 32 bytes from platform CSPRNG |
| Pairing identifier | 16 random bytes; identifier, not a secret |
| Stored pairing key | 32 bytes derived by HKDF |

P-256 is selected instead of X25519 because Android's standard API 26 providers
support `ECDH`/`secp256r1`, while macOS CryptoKit provides `P256.KeyAgreement`.
Public keys use the uncompressed ANSI X9.63 form and must be exactly 65 bytes.
No custom curve, hash, HMAC, or random-number implementation is allowed.

## First Pairing

Pairing is available only while the Android UI has opened a short-lived pairing
window. A background connection cannot silently create trust.

1. Mac creates an ephemeral P-256 key pair and a 32-byte `client_nonce`.
2. Mac sends a pairing-start request containing its ephemeral public key, nonce,
   display name, and supported authentication version.
3. Android verifies that the pairing window is open, creates its own ephemeral
   P-256 key pair, 32-byte `server_nonce`, and 16-byte `pairing_id`, then returns
   those values plus its stable Keystore-backed P-256 identity public key and an
   ECDSA signature over the canonical pairing transcript.
4. Mac verifies the identity signature before presenting approval. Both sides
   compute ECDH and the canonical pairing transcript. HKDF derives a
   confirmation key and candidate pairing key from the shared secret and transcript
   hash.
5. Both screens display the same six-digit short authentication string (SAS), with
   leading zeroes. The user must confirm that the codes match on both devices.
6. Mac sends a role-separated client confirmation after local approval. Android
   waits for its own local approval, validates the client confirmation, and returns
   a role-separated server confirmation binding both approval states.
7. Mac validates the server confirmation and atomically add-only writes a provisional
   non-synchronizing Keychain item. Any duplicate pairing ID fails without reading
   or updating the existing item. Mac then sends a final confirmation that proves receipt of the server
   proof. Android persists its Keystore-wrapped record only after validating this
  final confirmation. A finalization failure rolls back the provisional Mac item.
   After successful finalization, the Mac Core client hands that freshly persisted
   record directly to the immediate paired proof; it does not read the new item back.
8. Ephemeral private keys, shared secrets, and confirmation keys are discarded on
   success, rejection, timeout, or transport loss.

The Android identity key is self-asserted on first contact, not a public-CA
certificate. Its fingerprint becomes stable pairing metadata, while the compared
SAS is what authorizes that first binding. The SAS is derived from the confirmation key, not directly from public transcript
bytes. With one online attempt and a six-digit code, a blind substitution succeeds
with probability at most 1 in 1,000,000. Pairing failure closes the connection and
does not silently open a new attempt. Rate limiting is implemented as the
process-local policy described below and applies to the enabled product path.

The extra finalize round prevents asymmetric persistence when the server-confirm
response is lost in transit: Mac proves it received and validated the server proof
before Android commits. Mac persists provisionally before finalize so a lost final
response still leaves both sides with the same credential.

Peer names remain raw authenticated transcript/storage metadata, not trusted UI.
Android and Mac render only NFC-normalized, whitespace-collapsed projections with
control/format/surrogate code points removed and fixed fallbacks. Both cap the
visible result at 120 Unicode code points/scalars and reserve the last position
for an ellipsis when real visible input is truncated. This projection does not
change the transcript, SAS, pairing record, or revoke target. On Mac the Published
approval value contains only the safe Android label and six-digit SAS; the verified
device-identity fingerprint remains inside Core and credential lookup.

## Canonical Pairing Transcript and Derivation

Pairing never authenticates serialized protobuf bytes. Both implementations build:

```text
ascii  "DroidMatch pairing transcript v1\0"
u32be  pairing_version              # exactly 1
u16be  pairing_id_length
bytes  pairing_id                   # 16 bytes
u16be  client_public_key_length
bytes  client_public_key            # 65-byte uncompressed X9.63 P-256 point
u16be  server_public_key_length
bytes  server_public_key            # 65-byte uncompressed X9.63 P-256 point
u16be  device_identity_public_key_length
bytes  device_identity_public_key   # stable 65-byte uncompressed P-256 point
u16be  client_nonce_length
bytes  client_nonce                 # 32 bytes
u16be  server_nonce_length
bytes  server_nonce                 # 32 bytes
u16be  client_name_utf8_length
bytes  client_name_utf8             # 1...128 bytes
u16be  server_name_utf8_length
bytes  server_name_utf8             # 1...128 bytes
```

Android signs these exact transcript bytes with its stable P-256 identity key and
sends the DER-encoded ECDSA signature in `device_identity_signature`. Mac verifies
that signature before showing the SAS. The stored device identity fingerprint is
`SHA-256(device_identity_public_key)`.

`transcript_hash = SHA-256(transcript)`. ECDH returns the 32-byte P-256 shared
secret. Two independent HKDF-SHA-256 expansions use the transcript hash as salt:

```text
confirmation_key = HKDF(shared_secret, transcript_hash,
  "DroidMatch pairing confirmation key v1\0", 32)
pairing_key = HKDF(shared_secret, transcript_hash,
  "DroidMatch pairing key v1\0", 32)
```

The six-digit SAS uses HMAC-SHA-256 over
`"DroidMatch pairing SAS v1\0" || transcript_hash || u32be(counter)`. Interpret
the first four HMAC bytes as unsigned big-endian. Values at or above 4,294,000,000
are rejected and the counter increments; accepted values are reduced modulo
1,000,000 and zero-padded. Rejection sampling removes modulo bias.

Confirmation proofs are:

```text
client = HMAC(confirmation_key,
  "DroidMatch pairing client confirmation v1\0" || transcript_hash || 0x01)
server = HMAC(confirmation_key,
  "DroidMatch pairing server confirmation v1\0" || transcript_hash || 0x01 || 0x01)
final  = HMAC(confirmation_key,
  "DroidMatch pairing final confirmation v1\0" || transcript_hash || server)
```

The checked-in [pairing vector](../fixtures/crypto/pairing-v1.properties) covers
fixed test scalars 1 and 2 for ECDH, scalar 3 for the device identity, all public
keys, identity fingerprint, transcript, both derived keys, SAS, and all
confirmations in Swift and Java. The fixed scalars are test-only.

## Reconnection Authentication

Authentication is challenge-response after Hello, not a proof embedded only in
ClientHello. A ClientHello-only proof can be replayed because the client has not yet
seen a fresh server challenge.

1. ClientHello contains a fresh 32-byte client nonce and the non-secret pairing ID.
2. ServerHello echoes the client nonce, adds a fresh 32-byte server nonce, and marks
   the session `AUTHENTICATION_REQUIRED`. This does not complete the handshake and
   grants no destructive capability.
3. Both sides construct the same canonical session-auth transcript.
4. Mac sends `client_proof = HMAC(pairing_key, "client" || transcript_hash)`.
5. Android compares the proof in constant time. On success it returns
   `server_proof = HMAC(pairing_key, "server" || transcript_hash)` and the final
   granted capabilities.
6. Mac verifies the server proof in constant time. Both sides then mark the TCP
   session authenticated and derive a session-local key with HKDF.

A captured client proof cannot authenticate on another connection because the
server nonce changes. Proof failure returns one generic unauthorized error, records
only a redacted reason code, and closes the transport. The same pairing ID is rate
limited after repeated failures.

## Canonical Session Transcript

Do not HMAC serialized protobuf bytes: deterministic serialization and unknown-field
handling must not become a cross-language security dependency. The transcript is a
fixed byte sequence using big-endian integers and explicit length prefixes:

```text
ascii  "DroidMatch session auth v1\0"
u16be  pairing_id_length
bytes  pairing_id                    # exactly 16 bytes in v1
u16be  client_nonce_length
bytes  client_nonce                  # exactly 32 bytes in product auth
u16be  server_nonce_length
bytes  server_nonce                  # exactly 32 bytes
u32be  protocol_major
u32be  protocol_minor
u32be  transport_kind
```

The transcript hash is SHA-256 over exactly these bytes. Client and server proofs
use different ASCII role prefixes including their terminating NUL byte:

```text
client_proof = HMAC-SHA256(pairing_key, "DroidMatch client proof v1\0" || transcript_hash)
server_proof = HMAC-SHA256(pairing_key, "DroidMatch server proof v1\0" || transcript_hash)
session_key  = HKDF-SHA256(
  input_key_material = pairing_key,
  salt = transcript_hash,
  info = "DroidMatch session key v1\0",
  output_length = 32
)
```

The checked-in [fixed test vector](../fixtures/crypto/session-auth-v1.properties)
requires the Swift and Java implementations to produce identical transcript bytes,
hash, proofs, and session key.

## Capability Gating

Authentication state is independent from Android storage permission state. Both
checks are required.

| Session state | Maximum capability surface |
|---|---|
| Correlated but unpaired | Connection status, pairing UI, redacted diagnostics |
| Paired but not authenticated | Authentication messages only |
| Authenticated | Intersection of requested, build-channel, Android permission, and pairing-policy capabilities |
| Revoked/failed | Generic unauthorized error, then close |

File write/delete, install/uninstall, and future notification or screen-control
capabilities are never granted to a nonce-only session. Read-only file/media access
should also require authentication for the product build because filenames and media
metadata are private, even if the M1 debug harness temporarily exposes a narrower
diagnostic surface.

## Secret Storage

Mac:

- store the 32-byte pairing key as a non-synchronizing Keychain generic-password
  item scoped to DroidMatch;
- use pairing ID plus Android device identity fingerprint as lookup metadata;
- never place the key in UserDefaults, sidecars, shell environment, or CLI arguments.
- the implemented Keychain store uses a generic-password item with
  `kSecAttrSynchronizable = false`, rejects pairing-ID/device-fingerprint
  collisions, and keeps a versioned key-free selector/display envelope in the
  item's generic attribute. The UI display list validates that envelope—or a
  legacy item's account, label, and Keychain dates—without requesting password
  data. Explicit-connection selection loads only the fingerprint-matched current
  record. Legacy accounts use bounded per-item reads under one shared `LAContext`
  because macOS rejects generic-password `MatchLimitAll + ReturnData`; after all
  validate, every selector is backfilled. Successful reconnect does not rewrite
  the secret-bearing item merely for recency. After a fresh paired
  proof, the coordinator passes that already-validated Core credential into the
  same-generation invalidatable transfer gate instead of loading Keychain again,
  then clears its temporary reference. Teardown releases any credential that has
  not yet reached the gate.

Android:

- create a non-exportable AES-GCM wrapping key in Android Keystore;
- encrypt the derived pairing key before storing ciphertext and metadata in private
  app storage;
- bind pairing records to a stable DroidMatch device identity key, not Android ID,
  IMEI, or raw serial number;
- Keystore invalidation makes the pairing unusable and requires explicit re-pairing.
- the implemented Android vault encrypts each 32-byte key with AES-GCM under a
  non-exportable Android Keystore key. Pairing ID, device fingerprint, timestamps,
  and display name are authenticated as AAD; ciphertext/metadata stay in private
  SharedPreferences excluded from backup and device transfer.
- the authenticated display name remains verbatim transcript/credential metadata,
  but Android security-sensitive presentation never renders it directly. One
  UI-only projection NFC-normalizes and collapses whitespace, removes control,
  Unicode-format, and surrogate code points, and substitutes fixed `Mac` when no
  visible content remains. Pairing ID—not visible text—remains the revoke identity.

Both sides support list, rename, last-used timestamp, and revoke. Revocation deletes
the stored key and invalidates active sessions using that pairing ID.

## Wire-State Migration

The wire change remains backward-compatible at the protobuf field-number level but
changes the handshake state machine:

- ClientHello/ServerHello nonce correlation remains available as explicit
  `AUTHENTICATION_STATE_CORRELATED` M1 mode.
- `pairing_id`, `server_nonce`, authentication state, and typed
  `AuthenticateSessionRequest`/`AuthenticateSessionResponse` use new field and
  payload numbers.
- Android remains in `AWAITING_AUTH` after a paired ServerHello and moves to `READY`
  only after a valid client proof; out-of-order auth traffic closes the session.
- The Android product launcher/service injects its Keystore-backed repository and
  defaults to `PAIRED_REQUIRED`. Only the debug harness explicitly selects
  nonce-only mode for diagnostic and archived evidence workflows.
- Paired ServerHello grants no capabilities. The authenticated response grants only
  the intersection of requested and implemented M1 capabilities; the dispatcher
  enforces that set again for every RPC.
- Typed start, confirm, and finalize first-pairing messages are assigned. Their UI
  gated Android dispatcher and one-shot async Mac client are implemented. Android
  defaults to a closed 120-second visible window and waits at most 60 seconds for
  approval of one pending attempt; Mac transport timeout must exceed that approval
  interval.

Session-auth and first-pairing schema numbers are assigned in `proto/v1/rpc.proto`
and `proto/v1/session.proto`.

## Failure and Diagnostics Rules

- Pairing/authentication messages have a short independent timeout and no automatic
  infinite retry.
- First pairing and paired reconnect use process-local exponential backoff: three
  invalid attempts against one pairing flow trigger a one-second delay, doubling
  on each failure admitted after expiry up to 60 seconds. Reconnect additionally
  has a global bucket that starts backoff after ten admitted failures across IDs,
  preventing random-ID rotation from bypassing the per-ID policy.
- Reconnect still completes the normal challenge shape and proof calculation while
  blocked. Unknown IDs, bad proofs, and a correct proof during active backoff all
  receive the same generic unauthorized response. A valid admitted proof clears
  only that ID's bucket, not the global attack-pressure bucket.
- Backoff state expires after five idle minutes, tracks at most 256 identifiers,
  and is deliberately not persisted across process restart; durable attacker-driven
  lockout would create a worse denial-of-service boundary.
- Malformed public keys, nonce lengths, pairing IDs, or proofs are protocol errors;
  unknown/revoked pairing IDs and incorrect proofs share one external unauthorized
  response to reduce enumeration.
- Proof comparison is constant time.
- Diagnostics record state transitions, counters, algorithm/version, and lengths;
  they never record private keys, ECDH shared secrets, pairing keys, nonce bytes,
  transcript bytes, proof bytes, SAS values, or session keys.
- Support bundles may include the first eight hex characters of SHA-256(pairing ID)
  only when the user explicitly includes pairing diagnostics.

## Verification Status and Remaining Evidence

- done: shared Swift/Java canonical test vector;
- done: invalid length, malformed/off-curve P-256 point, and mutual ECDH tests;
- done: role-swap proof rejection;
- changed client nonce, server nonce, pairing ID, version, and transport each reject
  the old proof;
- done: replayed proof rejected on a fresh server nonce;
- done: constant-time proof comparison uses platform APIs;
- done: pairing window closed/open/expiry, single-pending-attempt, approval,
  rejection, and mismatched-attempt controller tests;
- done: Android dispatcher start/confirm/finalize persistence and fresh paired
  reconnect test, plus rejection/closed-window no-persistence tests;
- done: async Mac loopback tests for success, invalid identity signature, local
  rejection, and provisional Keychain rollback after finalize failure;
- done: first-pairing, per-ID reconnect, rotating-ID global, exponential delay,
  idle expiry, bounded-memory, and dispatcher integration rate-limit tests;
- done: injected-backend Keychain/vault save, update, collision, tamper, and revoke,
  plus a unique-service system-Keychain integration test;
- done: attended Android instrumentation archives stable/non-exportable P-256
  identity, non-exportable AES wrapping, record reopen, and revoke on Slot C;
- done: the product state machine denies every non-auth request before proof and
  grants only the authenticated capability intersection, which the dispatcher
  rechecks before file mutation/transfer handlers;
- done: Slot C archives ordinary and sandbox product authentication, Keychain
  reconnect, and product trust revocation;
- remaining: broader-matrix product insertion, physical credential-invalidation
  and rate-limit coverage, plus Developer ID signing/notarization evidence.
