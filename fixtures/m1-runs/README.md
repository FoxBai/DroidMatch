# M1 Run Logs

Store real-device M1 harness results here. `tools/run-m1-device-smoke.sh` writes a redacted log automatically after successful smoke runs and after device-stage failures that happen once a run log path is known.

Use the template in `docs/m1-device-matrix.md`. Do not commit logs that contain personal files, device serial numbers, private paths, access tokens, or unredacted support bundles.
Run `tools/check-m1-run-logs.sh` before committing new logs.

For upload smoke runs, prefer disposable filenames and `--cleanup-upload-destination` when targeting `dm://app-sandbox/`, `dm://media-images/`, or `dm://media-videos/`. For MediaStore/SAF fresh-only upload logs, prefer adding `--upload-resume-unsupported-check` so the run records that non-zero upload offsets still reject with `unsupportedCapability`. The script does not clean SAF uploads automatically, so only record SAF upload runs against a disposable user-selected directory or after manually removing the created file.
