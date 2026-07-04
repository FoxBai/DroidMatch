# M1 Real-Device Matrix

M1 validates the connection and file-transfer harness before product UI work starts. The matrix is intentionally small but must cover Android storage generations, vendor USB behavior, and both transport paths.

ADB runs first. AOA starts only after the ADB harness can exercise the same protocol surface.

## Required Devices

| Slot | Android Range | Device Class | Required Transport | Purpose |
|---|---|---|---|---|
| A | API 26-29, Android 8-10 | Legacy storage-era phone | ADB | Verify SAF/MediaStore-first behavior on the minimum supported generation. |
| B | API 30-32, Android 11-12L | Scoped-storage transition phone | ADB | Verify Android 11+ storage degradation and permission changes. |
| C | API 33-35, Android 13-15 | Recent mainstream phone | ADB and AOA candidate | Verify current permission prompts, media access, and AOA viability. |
| D | API 30+ | Non-Google domestic OEM phone | ADB | Verify vendor USB authorization, background service behavior, and package visibility differences. |
| E | API 30+ | Tablet or large-storage device | ADB | Verify large directory listings and 1GB transfer behavior. |

At least three physical devices must be available before M1 starts: one from slot A, one from slot C, and one domestic OEM or tablet device from slot D or E. AOA cannot be promoted beyond experimental unless at least two physical devices pass the AOA checks.

## M1 Harness Checks

Each required device should run:

- USB insertion to visible device time.
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
swift run --package-path mac droidmatch-harness list-dir --port <local-port> --path dm://media-images/
swift run --package-path mac droidmatch-harness list-dir --port <local-port> --path dm://media-videos/
swift run --package-path mac droidmatch-harness list-dir --port <local-port> --path dm://saf-<stable-id>/
```

The current transfer precursor can download a listed file path with one receiver-paced chunk in flight:

```text
swift run --package-path mac droidmatch-harness download-once --port <local-port> --source-path dm://media-images/media/<id>
swift run --package-path mac droidmatch-harness download-once --port <local-port> --source-path dm://saf-<stable-id>/<opaque-file-id>
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://saf-<stable-id>/<opaque-file-id> --destination /tmp/droidmatch-download.bin
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin --resume
swift run --package-path mac droidmatch-harness download --port <local-port> --source-path dm://media-images/media/<id> --destination /tmp/droidmatch-download.bin --retry-on-transport-loss
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --stop-after-bytes 1
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --resume
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://app-sandbox/droidmatch-upload.bin --retry-on-transport-loss
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.jpg --destination-path dm://media-images/droidmatch-upload.jpg
swift run --package-path mac droidmatch-harness upload --port <local-port> --source /tmp/droidmatch-upload.bin --destination-path dm://saf-<stable-id>/droidmatch-upload.bin
```

For debug APK real-device smoke, start the Android endpoint through the debug harness Activity:

```text
tools/run-m1-device-smoke.sh --serial <serial>
```

Pass `--handshake-attempts 20 --min-handshake-passes 19 --list-path dm://media-images/` to record handshake/heartbeat stability and first-list timing against the M1 pass threshold. Pass `--source-path <dm-path> --resume-check` to add an intentional partial download followed by `download --resume`; add `--download-retry-on-transport-loss` when the resume/full download should also exercise the one-attempt sidecar-backed reconnect path, or `--download-retry-fault-check` when a local frame proxy should drop the first transfer connection and require `recovered=true`. Pass `--source-path <dm-path> --cancel-check` / `--pause-check` to add first-chunk `download-cancel` / `download-pause` checks. Pass `--upload-source <local-file> --upload-destination-path dm://app-sandbox/<name> --min-upload-bytes <bytes>` to add an app-sandbox upload size gate; fresh-only upload destinations may also use `dm://media-images/<name>` or `dm://media-videos/<name>`, and writable SAF destinations may use `dm://saf-.../<name>` paths. Add `--upload-resume-unsupported-check` for MediaStore fresh-only destinations when the run should record that non-zero upload offsets return `unsupportedCapability`. Add `--cleanup-upload-destination` for app-sandbox or MediaStore smoke uploads that should be removed on exit. Add `--upload-resume-check --upload-partial-bytes <bytes>` to run intentional partial upload followed by app-sandbox or SAF `upload --resume`; add `--upload-retry-on-transport-loss` for app-sandbox/SAF runs that should record one-attempt retry from the saved ACK boundary, `--upload-retry-fault-check` to inject a local proxy disconnect and require `recovered=true`, or app-sandbox-only `--upload-retry-ack-loss-check` to drop the first upload ACK and require truncate/replay recovery. For a reproducible app-private 100MB download gate, pass `--prepare-app-sandbox-file dm-100mb-zero.bin --resume-check`; this creates a default 100MiB zero-filled file under `dm://app-sandbox/`, sets the source/list paths, and requires the observed final download size to meet the file size. Add `--chunk-size-bytes 1048576 --min-download-mib-per-second 20` to assert the ADB 100MiB download throughput gate with Android's current 1MiB negotiated chunk cap; the harness reports `elapsed_ms` and `throughput_mib_per_sec`, and the script writes both into the result log. Upload runs can use `--min-upload-mib-per-second <mibps>` for the same measurement and optional gate. The script installs the debug APK, verifies that the launcher resolves to `DiagnosticsActivity`, starts the debug harness Activity, allocates an ADB forward, runs `m1-smoke`, and writes a redacted result log under `fixtures/m1-runs/` unless `--no-result-log` is passed. The equivalent manual sequence is:

For temporary MediaStore upload smoke, prefer a unique display name plus cleanup:

```text
tools/run-m1-device-smoke.sh --upload-source /tmp/droidmatch-upload.jpg --upload-destination-path dm://media-images/droidmatch-smoke-<timestamp>.jpg --upload-resume-unsupported-check --min-upload-bytes 1 --cleanup-upload-destination --no-result-log
```

The unsupported-resume flag opens the same upload destination at offset 1 and requires `unsupportedCapability` before the fresh upload runs. The cleanup flag removes app-sandbox files and MediaStore rows created under DroidMatch's media subdirectory. It intentionally does not clean up SAF uploads; use a disposable SAF directory or remove those files manually until protocol-level delete/mutation support exists.

```text
adb shell am start -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity --ei port <android-port>
swift run --package-path mac droidmatch-harness forward --serial <serial> --remote-port <android-port>
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
- USB insertion to visible device is <= 5 seconds on each required device.
- First directory listing is <= 1 second on warm service for public media roots.
- 100MB ADB download is >= 20 MiB/s on at least three required devices, recorded from harness transfer elapsed time rather than build/install/list timing.
- Interrupted download resumes from the accepted offset without data corruption.
- Interrupted app-sandbox upload resumes from the accepted offset, tolerates first-ACK loss by truncating duplicate partial bytes, and commits the final destination.
- Sidecar-backed transport-loss retry reconnects once and completes with `recovered=true` under local frame-proxy fault injection, or reports a stable resume/transport failure reason.
- Fresh MediaStore upload commits into the expected image or video collection.
- Fresh SAF upload commits into a writable user-selected root and rejects read-only roots.
- Permission-denied, read-only, unauthorized, and transport-lost cases map to stable user-facing failure reasons.
- Diagnostics identify whether failure came from USB, ADB, AOA, Android service, permission, protocol, transfer, or Mac harness.

AOA passes its M1 gate only when:

- AOA handshake succeeds in at least 19 of 20 attempts on at least two devices.
- 100MB AOA download is >= 30 MB/s on at least two devices.
- Cable unplug/replug recovers within 3 seconds or reports a clear failure reason.

## Result Log Template

Record each run in `fixtures/m1-runs/`. `tools/run-m1-device-smoke.sh` writes this log automatically for its smoke coverage, including device-stage failures after a log path is known; manual matrix runs should use the same fields and avoid private paths, full device serials, personal files, access tokens, or unredacted support bundles.

```text
date:
device slot:
manufacturer/model:
android version/api:
build channel:
transport:
handshake attempts:
visible time:
first list time:
100MB download:
100MB upload:
resume result:
permission cases:
diagnostics bundle:
notes:
```
