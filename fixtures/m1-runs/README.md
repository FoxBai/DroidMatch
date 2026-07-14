# M1 Run Logs

Store real-device M1 harness results here. `tools/run-m1-device-smoke.sh` writes a redacted log automatically after successful smoke runs and after device-stage failures that happen once a run log path is known.

Use the template in `docs/m1-device-matrix.md`. Do not commit logs that contain personal files, device serial numbers, private paths, access tokens, or unredacted support bundles.
Run `tools/check-m1-run-logs.sh` before committing new logs.

For upload smoke runs, prefer disposable filenames and `--cleanup-upload-destination` when targeting `dm://app-sandbox/`, `dm://media-images/`, or `dm://media-videos/`. For MediaStore fresh-only upload logs, prefer adding `--upload-resume-unsupported-check` so the run records that non-zero upload offsets still reject with `unsupportedCapability`.

Use `--mixed-transfer-check --mixed-upload-destination-path <fresh-dm-path>` when a run should archive one async download, one async upload, and heartbeat on the same session. The mixed destination must differ from the ordinary `--upload-destination-path` and from the active download source. Prefer disposable app-sandbox or single-file MediaStore targets with `--cleanup-upload-destination`; the script records logical paths and byte totals but not the Mac upload path or file name.

Use `--list-expect-error-path <dm-path> --list-expect-error-code <code>` when a run should record a stable listing failure such as a missing SAF root or permission-required media root. Use `--media-permission-revoked-check` when a run should record that revoking media read permission makes media root listing return `permissionRequired`; the script records the permission mutation and restores prior media grants. Use `--source-path dm://media-images/media/<id> --media-permission-revoked-during-download-check` when a run should record media permission revocation during a MediaStore download; this check accepts a completed download or expected transport loss and should not be combined with throughput or minimum-byte gates.

Use `--download-open-expect-error-path <dm-path> --download-open-expect-error-code <code>` when a run should record a stable download-open failure such as a missing source or permission-required provider file. For writable SAF roots, prefer `--upload-resume-check` to record partial/resume. Add `--download-retry-on-transport-loss` or app-sandbox/SAF `--upload-retry-on-transport-loss` when the run should record the one-attempt sidecar-backed retry path; use `--download-retry-fault-check` or `--upload-retry-fault-check` when the log should prove recovery through the local frame proxy with `recovered=true`. Use app-sandbox-only `--upload-retry-ack-loss-check` when the run should prove first-ACK loss replay. For upload fault/ACK-loss evidence, the source must extend beyond the partial boundary plus the first four-chunk/2 MiB window so a dropped ACK cannot follow a completed atomic commit.

For 100MiB download matrix logs, add `--chunk-size-bytes 1048576 --min-download-mib-per-second 20` so the log records transfer elapsed time, observed MiB/s, and the throughput gate; upload logs may use `--min-upload-mib-per-second <mibps>`. The script does not clean SAF uploads automatically, so only record SAF upload runs against a disposable user-selected directory or after manually removing the created file.

The missing current-tip Slot A throughput result must use
`tools/run-m1-throughput-gate.sh --serial <serial> --expected-main-sha <40-hex>`.
That wrapper publishes `evidence profile: m1-adb-throughput-v1` only after clean
current-main provenance, API 26–29, one fresh exact-100MiB baseline/download/upload
run, requested and negotiated 1MiB chunks, both 20 MiB/s thresholds, terminal/log
serial/privacy scanning, fresh disposable-path reservation, and
remote/local/forward cleanup all pass. `check-m1-run-logs.sh`
applies strict numeric/profile validation only to logs carrying that exact profile;
the 84 historical fixtures retain their existing schema. Never copy the offline
fake-runner test output into this directory as physical evidence.
