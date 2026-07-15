# M1 Real-Device Matrix

M1 validates the enabled paired Mac product path and its reusable connection and
file-transfer harness. A green hosted build or the nonce-only debug harness does
not replace product/device evidence. The matrix is intentionally small but must
cover Android storage generations, vendor USB behavior, the current ADB path, and
the evidence needed before a future AOA path can be promoted.

ADB runs first. AOA starts only after the ADB harness can exercise the same protocol surface.

For step-by-step test instructions, see [docs/m1-testing-guide.md](m1-testing-guide.md).

## Required Devices

| Slot | Android Range | Device Class | Required Transport | Purpose |
|---|---|---|---|---|
| A | API 26-29, Android 8-10 | Legacy storage-era phone | ADB | Verify SAF/MediaStore-first behavior on the minimum supported generation. |
| B | API 30-32, Android 11-12L | Scoped-storage transition phone | ADB | Verify Android 11+ storage degradation and permission changes. |
| C | API 33-35, Android 13-15 | Recent mainstream phone | ADB and AOA candidate | Verify current permission prompts, media access, and AOA viability. |
| D | API 30+ | Non-Google domestic OEM phone | ADB | Verify vendor USB authorization, background service behavior, and package visibility differences. |
| E | API 30+ | Tablet or large-storage device | ADB | Verify large directory listings and 1GB transfer behavior. |

At least three physical devices must be available before M1 starts: one from slot A, one from slot C, and one domestic OEM or tablet device from slot D or E. AOA cannot be promoted beyond experimental unless at least two physical devices pass the AOA checks. That promotion gate is separate and does not block completion of the current ADB M1 path.

## M1 Harness Checks

Each required device should run:

- Attended USB insertion to one identified product discovery card, with current-main
  release App provenance and a validated `m1-product-usb-insertion-v1` fixture.
- ADB authorization and reconnect.
- DroidMatch service reachability.
- `ClientHello` / `ServerHello` handshake.
- `DeviceInfoRequest`.
- `ListDirRequest` on a public media root and a user-selected SAF root.
- 100MB download using `OpenTransfer` and `TransferChunk`.
- 100MB upload using `OpenTransfer` and `TransferChunk`.
- Fresh upload into a MediaStore image or video collection.
- Fresh upload into a user-selected writable SAF root.
- Cable unplug/replug during transfer.
- Resume from interrupted offset.
- `CancelTransferRequest` and `PauseTransferRequest`.
- Diagnostics export with recent state transitions and errors.

For the current ADB harness, public media root listing can be exercised with:

```text
swift run --package-path mac --configuration release droidmatch-harness list-dir --port <local-port> --path dm://media-images/
swift run --package-path mac --configuration release droidmatch-harness list-dir --port <local-port> --path dm://media-videos/
swift run --package-path mac --configuration release droidmatch-harness list-dir --port <local-port> --path dm://saf-<stable-id>/
```

The current transfer path can download a listed file path on one stream; after
the first ACK Android keeps the stream filled up to the M1 window cap of 4
chunks or 2 MiB in flight:

```text
swift run --package-path mac --configuration release droidmatch-harness download-once --port <local-port> --source-path dm://media-images/media/<id>
swift run --package-path mac --configuration release droidmatch-harness download-once --port <local-port> --source-path dm://saf-<stable-id>/<opaque-file-id>
swift run --package-path mac --configuration release droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /private/tmp/droidmatch-download.bin
swift run --package-path mac --configuration release droidmatch-harness download --port <local-port> --source-path dm://saf-<stable-id>/<opaque-file-id> --destination /private/tmp/droidmatch-download.bin
swift run --package-path mac --configuration release droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /private/tmp/droidmatch-download.bin --resume
swift run --package-path mac --configuration release droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /private/tmp/droidmatch-download.bin --retry-on-transport-loss
swift run --package-path mac --configuration release droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin
swift run --package-path mac --configuration release droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --stop-after-bytes 1
swift run --package-path mac --configuration release droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --resume
swift run --package-path mac --configuration release droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --retry-on-transport-loss
swift run --package-path mac --configuration release droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.jpg --destination-path dm://media-images/droidmatch-upload.jpg
swift run --package-path mac --configuration release droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://saf-<stable-id>/droidmatch-upload.bin
swift run --package-path mac --configuration release droidmatch-harness download-open-expect-error --port <local-port> --source-path dm://app-sandbox/missing.bin --expected-error-code notFound
```

The download writer pins the destination's direct parent with `O_NOFOLLOW`.
Use `/private/tmp` (or another real directory) rather than macOS's `/tmp`
symlink for direct-child download destinations. Read-only upload sources may
still live under `/tmp`.

For debug APK real-device smoke, start the Android endpoint through the debug harness Activity:

```text
tools/run-m1-device-smoke.sh --serial <serial>
```

Pass `--handshake-attempts 20 --min-handshake-passes 19 --list-path dm://media-images/` to record handshake/heartbeat stability and first-list timing against the M1 pass threshold. Pass `--list-expect-error-path <dm-path> --list-expect-error-code <code>` to record a stable expected listing failure such as an unauthorized/missing SAF root or a permission-required media root. Pass `--media-permission-revoked-check` to revoke media read permission, require a media root listing to return `permissionRequired`, and restore the media grants that were present before the check.

Pass `--source-path dm://media-images/media/<id> --media-permission-revoked-during-download-check` to route a MediaStore download through the local frame proxy, revoke media read permission after the first proxied server frames, accept either a completed download or expected transport loss, and restore the prior grants. Do not combine this check with throughput or minimum-byte gates; it records permission-mutation behavior, not complete-file transfer performance.

Pass `--download-open-expect-error-path <dm-path> --download-open-expect-error-code <code>` to record a stable expected download-open failure such as a missing source or permission-required provider file. Pass `--source-path <dm-path> --resume-check` to add an intentional partial download followed by `download --resume`; add `--download-retry-on-transport-loss` when the resume/full download should also exercise sidecar-backed reconnect, or `--download-retry-fault-check` when a local frame proxy should drop the first transfer connection and require `recovered=true`. Pass `--max-retry-attempts N` and `--retry-backoff-ms M` with retry/fault checks to record a non-default recovery queue policy; without these flags the harness keeps the legacy single retry. Pass `--source-path <dm-path> --cancel-check` / `--pause-check` to add first-chunk `download-cancel` / `download-pause` checks.

Pass `--source-path <dm-path> --dual-download-check` to open two independent readers for the same source on one session, require a heartbeat while both streams are active and neither first chunk has been acknowledged, then record both routed stream results. Prefer a script-created app-sandbox source for reproducible, disposable matrix evidence.

Pass `--upload-source <local-file> --upload-destination-path dm://app-sandbox/<name> --min-upload-bytes <bytes>` to add an app-sandbox upload size gate; fresh-only upload destinations may also use `dm://media-images/<name>` or `dm://media-videos/<name>`, and writable SAF destinations may use `dm://saf-.../<name>` paths. Add `--upload-resume-unsupported-check` for MediaStore fresh-only destinations when the run should record that non-zero upload offsets return `unsupportedCapability`. Add `--cleanup-upload-destination` for app-sandbox, MediaStore, or direct-root single-file SAF smoke uploads that should be removed on exit; nested process-local SAF document-token destinations still require explicit cleanup. Add `--upload-resume-check --upload-partial-bytes <bytes>` to run intentional partial upload followed by app-sandbox or SAF `upload --resume`; add `--upload-retry-on-transport-loss` for app-sandbox/SAF runs that should record retry from the saved ACK boundary, `--upload-retry-fault-check` to inject a local proxy disconnect and require `recovered=true`, or app-sandbox-only `--upload-retry-ack-loss-check` to drop the first upload ACK and require truncate/replay recovery.

The upload disconnect-fault and ACK-loss probes are mutually exclusive; archive
them in separate runs so each `recovered=true` result stays direction- and
fault-specific.

For a reproducible app-private 100MB download gate, pass `--prepare-app-sandbox-file dm-100mb-zero.bin --resume-check`; this creates a default 100MiB zero-filled file under `dm://app-sandbox/`, sets the source/list paths, and requires the observed final download size to meet the file size. Add `--chunk-size-bytes 1048576 --min-download-mib-per-second 20` to assert the ADB 100MiB download throughput gate with Android's current 1MiB negotiated chunk cap. A matching 100MiB app-sandbox upload must use `--min-upload-mib-per-second 20`. The harness reports `elapsed_ms` and `throughput_mib_per_sec`, and the script writes both into the result log.

The physical-device runner builds and invokes `droidmatch-harness` with Swift's
release configuration. A debug/Onone measurement is diagnostic only and cannot
satisfy either throughput gate. In particular, the archived Slot A throughput
runs predate the current transfer optimizations and were measured with the old debug
harness; they must not be treated as current-tip evidence.

For the missing current-tip Slot A result, use the fail-closed profile after
fetching and reviewing the exact remote `main` SHA:

```text
tools/run-m1-throughput-gate.sh \
  --serial <serial> \
  --expected-main-sha <40-hex-origin-main-sha>
```

`m1-adb-throughput-v2` rejects a dirty/stale tree, a non-API-26–29 device,
debug/Onone or skip-build Mac harness reuse, non-fresh or non-exact 100MiB transfers, requested or
negotiated chunks other than 1MiB, either direction below 20 MiB/s, missing raw
ADB baseline, unequal managed/download/upload SHA-256 digests, raw-serial
publication, and incomplete remote/local/forward cleanup. Digest verification is
performed after the timed product transfers. It publishes the fixture only after
content and cleanup verification; its offline test uses fake ADB/runner processes
and is not physical evidence. The profile is pass-only and is the only profile
that can satisfy Slot A; throughput v1 is rejected.

After the same clean current-main/API 26–29 preflight, a failed wrapper may publish
the separate fail-only `m1-adb-throughput-diagnostic-v1` while returning non-zero,
but only if the private `m1-device-smoke-v1` producer first passes standalone
validation. Its combined archive embeds that validated producer record and
retains available metrics plus fixed
failure stage, source/expected/origin binding, post-run provenance, producer
exit/result, recorded managed/download/upload digests, and aggregate remote/local/
forward cleanup state. It never satisfies a matrix criterion. An invalid or
missing producer, privacy or validator failure, or no-clobber publication race
produces no diagnostic fixture.

The script installs the debug APK, verifies that the launcher resolves to `DroidMatchActivity`, starts the separate debug harness Activity, allocates an ADB forward, runs `m1-smoke`, and writes a redacted result log under `fixtures/m1-runs/` unless `--no-result-log` is passed. Captured output and the staged log pass through the shared `tools/m1-output-redaction.sh` boundary, which removes local paths, logical remote paths, names, notes, and serials before terminal display or publication. The equivalent manual sequence is:

For temporary MediaStore upload smoke, prefer a unique display name plus cleanup:

```text
tools/run-m1-device-smoke.sh --upload-source /tmp/droidmatch-upload.jpg --upload-destination-path dm://media-images/droidmatch-smoke-<timestamp>.jpg --upload-resume-unsupported-check --min-upload-bytes 1 --cleanup-upload-destination --no-result-log
```

The unsupported-resume flag opens the same upload destination at offset 1 and requires `unsupportedCapability` before the fresh upload runs. The cleanup flag removes app-sandbox files, MediaStore rows created under DroidMatch's media subdirectory, and direct-root single-file SAF targets through a fresh authenticated `delete-path` session. Nested `dm://saf-.../doc/<directory-token>/...` targets still require explicit cleanup because the document token is a process-local capability; resumable hidden partials and temporary grants must also be checked separately.

```text
adb shell am start -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity --ei port <android-port>
swift run --package-path mac --configuration release droidmatch-harness forward --serial <serial> --remote-port <android-port>
```

This keeps the app foreground while the service listens. On the NIO N2301 run, starting only the service left the process in a device freezer state: ADB forward reached the kernel socket queue, but the Java accept thread did not run until the debug Activity was foreground.

AOA-capable devices additionally run:

- Accessory permission grant and denial.
- Endpoint open and teardown.
- Handshake over AOA.
- 100MB transfer throughput.
- Cable unplug/replug recovery.

## Pass Criteria

M1 passes only when:

- ADB handshake succeeds in at least 19 of 20 attempts on each required device.
- USB insertion to visible device is <= 5 seconds on each required device, measured
  from the monotonic-before-`INSERT NOW` boundary and archived through the strict
  product-insertion profile.
- First directory listing is <= 1 second on warm service for public media roots.
- 100MB ADB download is >= 20 MiB/s on the same three selected required devices (one Slot A, one Slot C, and one Slot D or E), recorded from a release-configured harness's transfer elapsed time rather than build/install/list timing.
- 100MB ADB upload is >= 20 MiB/s on that same selected three-device set, recorded from a release-configured harness's transfer elapsed time.
- Interrupted download resumes from the accepted offset without data corruption.
- Interrupted app-sandbox upload resumes from the accepted offset, tolerates first-ACK loss by truncating duplicate partial bytes, and commits the final destination.
- Sidecar-backed transport-loss retry completes with `recovered=true` under local frame-proxy fault injection, records the retry policy when `--max-retry-attempts`/`--retry-backoff-ms` are provided, or reports a stable resume/transport failure reason.
- Fresh MediaStore upload commits into the expected image or video collection.
- Fresh SAF upload commits into a writable user-selected root and rejects read-only roots.
- Permission-denied, read-only, unauthorized, and transport-lost cases map to stable user-facing failure reasons.
- Diagnostics identify whether failure came from USB, ADB, AOA, Android service, permission, protocol, transfer, or Mac harness.

The separate AOA experimental-promotion gate passes only when:

- AOA handshake succeeds in at least 19 of 20 attempts on at least two devices.
- 100MB AOA download is >= 30 MB/s on at least two devices.
- Cable unplug/replug recovers within 3 seconds or reports a clear failure reason.

## Result Log Contract

Record eligible ordinary runs in `fixtures/m1-runs/` through
`tools/run-m1-device-smoke.sh`. It publishes a single
`m1-device-smoke-v1` profile for successful runs and for device-stage failures
after a log path is known. Do not hand-author a new log from the display fields:
the checker requires the recorded source revision/state and build/APK identity,
slot/API consistency,
canonical requested/passed/incomplete check sets, result/archive-class
relationships, per-attempt transfer-rate arithmetic, fresh-transfer measured/final
byte equality, and metric/summary agreement. Resume/retry records may have a
larger final offset than the bytes moved by their final measured attempt.
Only a clean, rebuilt, full-revision run is `device-evidence`; passing runs from a
dirty/unknown source state or reused APK are `diagnostic-only`. A failed run is
archived as `failed-diagnostic`. Neither diagnostic class can satisfy a matrix
criterion.

The throughput wrapper's `m1-adb-throughput-diagnostic-v1` is likewise a
failure-only investigation record, not a relaxed form of the pass-only v2 gate.

The 89 older unprofiled fixtures are accepted only at their byte-exact paths in
`fixtures/m1-runs/legacy-v0.sha256`. Do not edit them or recompute that manifest.
A special attended workflow that the ordinary runner cannot express must first
define a dedicated versioned profile and validator; copying the old free-form
field layout is not an evidence path. All logs must omit private paths, full
device serials, personal files, access tokens, and unredacted support bundles.
Schema validation makes recorded evidence internally consistent and review-visible
but does not cryptographically attest that the physical action occurred or place
the in-repository manifest outside normal code review.
