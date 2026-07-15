# M1 Run Logs

Store redacted real-device M1 harness results here. New ordinary runs must be
published by `tools/run-m1-device-smoke.sh` with the single versioned profile
`m1-device-smoke-v1`; do not hand-author a replacement log from the human-readable
fields. The profile records the full source revision and state, build/APK identity, slot/API,
requested/passed/incomplete checks, final offsets, per-attempt measured bytes,
thresholds, measured transfer values, result class, and cleanup intent. Fresh
non-retry transfers require measured bytes to equal the final offset; explicit
resume/retry records may differ. The checker rejects duplicate, unknown, or
internally contradictory fields. Only a
clean, rebuilt, full-revision run is classified as `device-evidence`; a passing
dirty/unknown/reused run is `diagnostic-only`, and a `failed-diagnostic` archive
is useful for investigation but never passing device evidence.

The 89 pre-profile fixtures are a review-frozen legacy archive. Their paths and
bytes are pinned by `legacy-v0.sha256`; never edit an archived legacy log or
recompute the manifest to make drift pass. The in-repository manifest and checker
constant make accidental or unreviewed drift visible, not externally signed or
independently immutable. Any new unprofiled log is rejected.
Specialized attended workflows must use their own versioned profile, producer,
and checker before their output is eligible for archival.

Do not commit logs that contain personal files, device serial numbers, private
paths, access tokens, or unredacted support bundles. Run
`tools/check-m1-run-logs.sh` before committing new logs. These checks establish
schema, semantic consistency, recorded provenance, privacy boundaries, and
legacy byte integrity; a text log is not cryptographic proof that a physical run
occurred.

For upload smoke runs, prefer disposable filenames and `--cleanup-upload-destination` when targeting `dm://app-sandbox/`, `dm://media-images/`, or `dm://media-videos/`. For MediaStore fresh-only upload logs, prefer adding `--upload-resume-unsupported-check` so the run records that non-zero upload offsets still reject with `unsupportedCapability`.

Use `--mixed-transfer-check --mixed-upload-destination-path <fresh-dm-path>` when a run should archive one async download, one async upload, and heartbeat on the same session. The mixed destination must differ from the ordinary `--upload-destination-path` and from the active download source. Prefer disposable app-sandbox or single-file MediaStore targets with `--cleanup-upload-destination`; the script records logical paths and byte totals but not the Mac upload path or file name.

Use `--list-expect-error-path <dm-path> --list-expect-error-code <code>` when a run should record a stable listing failure such as a missing SAF root or permission-required media root. Use `--media-permission-revoked-check` when a run should record that revoking media read permission makes media root listing return `permissionRequired`; the script records the permission mutation and restores prior media grants. Use `--source-path dm://media-images/media/<id> --media-permission-revoked-during-download-check` when a run should record media permission revocation during a MediaStore download; this check accepts a completed download or expected transport loss and should not be combined with throughput or minimum-byte gates.

Use `--download-open-expect-error-path <dm-path> --download-open-expect-error-code <code>` when a run should record a stable download-open failure such as a missing source or permission-required provider file. For writable SAF roots, prefer `--upload-resume-check` to record partial/resume. Add `--download-retry-on-transport-loss` or app-sandbox/SAF `--upload-retry-on-transport-loss` when the run should record the one-attempt sidecar-backed retry path; use `--download-retry-fault-check` or `--upload-retry-fault-check` when the log should prove recovery through the local frame proxy with `recovered=true`. Use app-sandbox-only `--upload-retry-ack-loss-check` when the run should prove first-ACK loss replay. For upload fault/ACK-loss evidence, the source must extend beyond the partial boundary plus the first four-chunk/2 MiB window so a dropped ACK cannot follow a completed atomic commit.

The upload disconnect-fault and ACK-loss probes are mutually exclusive and must
be archived in separate runs so each `recovered=true` result stays fault-specific.

When combining `--download-resume-source-mutation-check` or `--download-resume-source-deletion-check` with cancel/pause probes, the runner recreates the script-owned disposable source after the expected resume rejection. This keeps each later probe independent while preserving the destructive source assertion.

For 100MiB download matrix logs, add `--chunk-size-bytes 1048576 --min-download-mib-per-second 20` so the log records transfer elapsed time, observed MiB/s, and the throughput gate; upload logs may use `--min-upload-mib-per-second <mibps>`. The script does not clean SAF uploads automatically, so only record SAF upload runs against a disposable user-selected directory or after manually removing the created file.

The missing current-tip Slot A throughput result must use
`tools/run-m1-throughput-gate.sh --serial <serial> --expected-main-sha <40-hex>`.
That wrapper publishes `evidence profile: m1-adb-throughput-v2` only after clean
current-main provenance, API 26–29, one fresh exact-100MiB baseline/download/upload
run, requested and negotiated 1MiB chunks, both 20 MiB/s thresholds, identical
managed/download/upload SHA-256 digests, terminal/log serial/privacy scanning,
fresh disposable-path reservation, and remote/local/forward cleanup all pass. The
digest reads happen after the timed product transfers. `check-m1-run-logs.sh`
first validates the embedded `m1-device-smoke-v1` producer record, then binds its
full source revision, fixed check plan, overlapping metrics, and fixed managed
payload to the specialized throughput record. The v2 profile remains pass-only
and is the sole profile that can satisfy Slot A. Throughput v1 is rejected rather
than left as a downgrade path.

After strict preflight, a wrapper failure may publish the distinct fail-only
`m1-adb-throughput-diagnostic-v1` while still returning non-zero, but only when its
private `m1-device-smoke-v1` producer first passes standalone validation. The
combined diagnostic archive embeds that validated producer record, retains its
available metrics, and adds only bounded
failure stage, source/expected/origin binding, post-run provenance, producer
exit/result, recorded managed/download/upload digests, and aggregate remote/local/
forward cleanup state. It never satisfies a gate. Invalid or missing producers,
privacy or validator failures, and no-clobber publication races create no
diagnostic fixture. Never copy offline fake-runner output into this directory as
physical evidence.
