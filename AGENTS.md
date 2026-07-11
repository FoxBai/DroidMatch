# DroidMatch Agent Guide

This file is the durable repository contract for human contributors and coding
agents. Read it together with the root `README.md`; a more deeply nested
`AGENTS.md`, if one is added later, may narrow these rules for its subtree.

## Current phase and reading order

DroidMatch is still in M1 transport and protocol validation. Its SwiftUI macOS
product target now owns async, serial-redacted ADB discovery, dynamic forward
leases, paired authentication, visible SAS approval, and a live read-only file
browser plus a structured privacy-bounded diagnostics page. Its device-isolated
persistent download/upload queue uses fresh authenticated clients, native file
panels, provider-aware retry rules, and App-owned security-scoped bookmark leases.
The sandbox-entitled bundle, embedded adb discovery, and mount-verified local DMG
are verified locally. Sandbox file transfer, archived product-auth/transfer
evidence, Developer ID signing, notarization, and release automation are not
product-complete.
The Android launcher is secure connection, pairing, paired-Mac trust, and folder
authorization management rather than a full local file-manager UI.
Do not describe placeholders or post-M1 features as implemented.

Before changing behavior, read the smallest relevant set:

1. `README.md` and `docs/m1-status.md` for current scope and evidence.
2. `docs/architecture.md`, `docs/protocol.md`, and
   `docs/protocol-runtime.md` for ownership and wire behavior.
3. `docs/path-model.md` and `docs/security-model.md` for path and trust
   boundaries.
4. `mac/README.md` plus `docs/mac-code-overview.md` for Mac work, or
   `android/README.md` plus `docs/android-code-overview.md` for Android work.
5. `docs/ci-cd.md` and `docs/m1-testing-guide.md` before changing gates or
   physical-device workflows.
6. `docs/maintainer-runbook.md` before handoff, incident response, or release work.

Historical session notes and fixture logs are evidence, not the source of truth
for current scope. If they conflict with `docs/m1-status.md` or current code,
verify the behavior and update the live document instead of copying stale text.

## Architecture boundaries

- Product UI must depend on domain/session/transfer interfaces. It must not
  parse protobuf frames, run raw ADB commands, or own retry policy.
- Mac transport code owns byte movement and connection state. RPC code owns
  request IDs, response matching, envelopes, and error normalization. Transfer
  code owns checkpoints, retry/resume decisions, integrity checks, and atomic
  destination commits.
- The CLI harness is a consumer of reusable core behavior. New product logic
  must not live only in `DroidMatchHarness/main.swift`.
- Android `RpcDispatcher` owns protocol routing, not provider-specific storage
  rules. MediaStore, SAF, and app-sandbox behavior must remain behind provider
  interfaces.
- Android permission state is live state. Never cache a grant as a permanent
  setup fact, and never infer file/media authorization from transport access.
- Keep ADB and future AOA behavior behind the same semantic protocol surface.
  AOA remains experimental until its documented device gates pass.
- Keep HandShaker research isolated. Do not reuse its code, binaries, branding,
  signing material, private endpoints, or copied UI assets.

Handwritten production and test files share the repository's 850-line ceiling.
Large existing files may be split incrementally. Prefer behavior-preserving
extraction with tests over simultaneous rewrites, language migrations, or broad
directory reshuffles.

## Protocol and transfer invariants

- `proto/v1/*.proto` is the shared wire source of truth. Never reuse or
  renumber an existing protobuf field or enum value. Additive changes require
  compatible handling on both platforms and matching documentation.
- Do not manually edit generated Swift protobuf files. Regenerate them with
  `bash tools/generate-swift-proto.sh`; Android Java lite sources are generated
  by Gradle.
- Reject frames outside the documented size bounds before allocating their full
  payload. Transfer chunks remain capped by negotiated limits.
- A session must complete `ClientHello`/`ServerHello` before other requests.
  Request and stream IDs must be non-zero where the protocol requires them and
  must be scoped to the active session.
- Download resume requires a stable source fingerprint and must reject missing,
  changed, or deleted sources. Never silently restart a stale resume as a fresh
  transfer.
- Upload resume must reconcile the provider partial with the last durable Mac
  acknowledgement. Preserve the documented app-sandbox ACK-loss truncate and
  replay behavior.
- Downloads stay in a partial file until an atomic final commit. Failed or
  cancelled operations must not replace an existing destination.
- Validate CRC32 and offsets before accepting or persisting transfer progress.
  Preserve the per-stream in-flight limits of 4 chunks or 2 MiB until an
  explicitly tested protocol change replaces them.
- Map failures to stable `ErrorCode` values. Do not leak raw platform exceptions,
  private paths, content URIs, or credentials into wire errors.

## Security and privacy invariants

- ADB endpoints bind to loopback only and are closed with service/session
  teardown. Do not broaden the listening interface for convenience.
- Treat the current nonce exchange as an M1 freshness placeholder, not strong
  authentication. Any implementation of destructive product operations must
  define and test an explicit session authorization boundary first.
- SAF access requires current persisted URI permission. Provider operations
  must re-check the permission/capability they need.
- App-sandbox paths must remain canonicalized under the configured root. Raw
  `content://` URIs and Android document IDs must never cross the wire.
- Redact device serials, absolute home paths, authorization headers, API keys,
  tokens, signing material, and personal file names from normal logs and test
  fixtures. Never place raw user file contents in diagnostics.
- Do not read, print, commit, or transmit local credentials while using an
  external model. Share only repository content and already-redacted evidence.

## Code, comments, and documentation

- Keep changes small enough to review and verify. Avoid unrelated formatting or
  dependency upgrades in a behavior change.
- Comments should explain invariants, ownership, non-obvious platform behavior,
  and why a workaround exists. Do not narrate straightforward syntax.
- Public/shared workflow comments and operator-facing messages should retain
  the repository's paired English/Chinese convention when practical.
- Update the matching live documentation in the same change whenever protocol,
  security, transport, Android service behavior, Mac harness behavior, gates,
  or verified device status changes.
- Do not update fixture counts or mark a device criterion passed without a real,
  redacted physical-device run. Never fabricate or edit evidence to satisfy a
  gate.
- Add release notes or status claims only for behavior demonstrated by tests or
  an archived device run.

## Verification

Run the narrowest relevant checks while iterating, then the full affected gate
before handoff.

Documentation or protocol-only work:

```text
bash tools/check-m0.sh
python3 tools/check-source-size.py
bash tools/check-proto.sh
python3 tools/check-doc-links.py
bash tools/check-m1-run-logs.sh
```

Mac work:

```text
bash tools/check-env.sh --swift
bash tools/run-swift-tests.sh
```

Android work:

```text
bash tools/check-env.sh --android
cd android
./gradlew --no-daemon :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

Cross-platform protocol, transfer, or gate work:

```text
bash tools/check-m1-skeleton.sh
```

Physical-device scripts are opt-in. Run them only when an attached disposable
test device and the required permissions/cleanup plan are explicit.

## Multi-model development workflow

- Give every implementation task a written contract: goal, allowed files,
  invariants, acceptance commands, non-goals, and stop conditions.
- Use MiMo 2.5 Pro as the default long-horizon implementation model. Use GLM
  5.2 for difficult cross-module refactors and deep debugging. Use DeepSeek V4
  Flash for bounded test expansion, mechanical cleanup, and documentation
  consistency work. Use GPT models for product/spec decisions, security and
  architecture review, visual review, and final integration judgment.
- A model must not be the sole approver of its own patch. Use a different model
  family for review, and let repository tests and device evidence outrank model
  confidence.
- Only one writer may own a file set at a time. Use separate branches/worktrees
  for genuinely parallel changes; never let multiple agents race in one
  worktree.
- Prefer focused context packs over sending the entire repository repeatedly.
  Reuse stable instructions and cached prefixes, and stop a run that is looping,
  repeatedly rereading files, or spending tokens without producing a verifiable
  artifact.

For low-token, model-bound reviews through the installed ZCode app, use the
repository wrapper instead of headless `zcode -p` (which does not expose model
selection in ZCode 0.15.0):

```text
tools/zcode-model-prompt.mjs --list-models
tools/zcode-model-prompt.mjs --model mimo --prompt-file /tmp/review-prompt.txt
printf '%s' '<focused context and question>' | tools/zcode-model-prompt.mjs --model deepseek
```

The aliases are `mimo` → `mimo-v2.5-pro`, `glm` → `glm-5.2`, and `deepseek` →
`deepseek-v4-flash`. The wrapper reads the live app-server catalog, uses
`workspace/generateText` so it does not inject the full agent tool schema, and
rejects a response unless its returned model reference matches the request. It
does not read or print credential configuration. For structured reviews, ask the
model to end with a unique marker and pass the same text through
`--require-suffix`; this turns provider truncation into an explicit failure.
Keep prompts focused and use GPT for final integration judgment as required above.

## Worktree hygiene

- Preserve user changes and unrelated dirty files. Never use destructive reset
  or checkout commands to clean the worktree.
- Keep generated build output, local SDK paths, credentials, and temporary model
  configuration out of Git.
- Before handoff, inspect `git diff`, report every changed file, list the checks
  actually run, and call out any unverified physical-device behavior.
