# Security Model

DroidMatch is local-first and USB-first, but local USB does not mean trust everything. M1 should keep the trust boundary explicit even before product UI polish.

## Trust Boundaries

- The Mac app and Android service are both DroidMatch-controlled code.
- ADB authorization proves that the user allowed this Mac to talk to the device through Android's debugging channel.
- ADB forward exposes a localhost port on the Mac. Other local Mac processes may attempt to connect.
- AOA exposes a USB accessory channel. It must not imply file or media permissions.
- Support bundles may contain sensitive file names, paths, device metadata, and timing information.

## M1 Session Authentication

M1 reserves nonce fields for a lightweight session challenge before accepting control-plane requests after handshake:

- Android generates a random session nonce when the transport endpoint opens.
- Mac and Android exchange redacted nonce material through `ClientHello.session_nonce` and `ServerHello.session_nonce` once the first harness is ready to enforce it.
- Android binds accepted requests to the active transport endpoint and negotiated session.
- Requests received before handshake completion are rejected with `ERROR_CODE_UNAUTHORIZED`.

The first M1 framing skeleton may leave nonce fields empty. This is not a replacement for user-facing pairing or TLS. It is a guard against stale local connections and accidental cross-session reuse during M1 harness work.

## ADB Forward Port Safety

- Bind forwarded services to localhost only.
- Allocate dynamic ports and record them in diagnostics.
- Reject non-DroidMatch traffic with `ERROR_CODE_PROTOCOL_ERROR`.
- Close the service endpoint when the foreground service stops or transport teardown begins.
- Do not kill the user's adb-server as routine recovery.

M1 does not require TLS over ADB forward. Revisit TLS or a stronger challenge-response before v1.0 if the threat model expands beyond local user-owned machines.

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
- Never include raw file contents in diagnostics.
- Support bundles must mark whether paths were redacted.

## Legacy Research Boundary

Security rules do not loosen for HandShaker compatibility research. Legacy notes may describe observed behavior, but must not include old binaries, keys, credentials, private endpoints, or copied implementation details.

## Open Security Work for M1

M1 should produce evidence for:

- Whether localhost ADB forwarding needs a stronger local authentication mechanism.
- Whether AOA requires payload CRC on all frames for observed device stability.
- Which diagnostics fields are too sensitive to include by default.
- Whether non-Play enhanced storage modes need an explicit user-visible risk warning.
