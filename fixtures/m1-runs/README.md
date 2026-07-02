# M1 Run Logs

Store real-device M1 harness results here. `tools/run-m1-device-smoke.sh` writes a redacted log automatically after successful smoke runs and after device-stage failures that happen once a run log path is known.

Use the template in `docs/m1-device-matrix.md`. Do not commit logs that contain personal files, device serial numbers, private paths, access tokens, or unredacted support bundles.
Run `tools/check-m1-run-logs.sh` before committing new logs.
