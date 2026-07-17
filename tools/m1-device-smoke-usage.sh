#!/usr/bin/env bash

# Defines the public CLI/environment contract only. The caller owns parsing,
# device state, evidence, and cleanup.
usage() {
  cat <<'USAGE'
Run the M1 debug APK on one adb-visible Android device and execute the Mac smoke harness.

Usage:
  tools/run-m1-device-smoke.sh [options]

Options:
  --serial <serial>              adb device serial. Required when multiple devices are ready.
  --remote-port <port>           Android endpoint port. Default: 39001.
  --local-port <port>            Mac forward port, or 0 for adb-allocated. Default: 0.
  --timeout-seconds <seconds>    Harness TCP timeout. Default: 10.
  --handshake-attempts <count>   Number of m1-smoke attempts to run. Default: 1.
  --min-handshake-passes <count> Minimum successful m1-smoke attempts. Default: handshake-attempts.
  --list-path <dm-path>          Optional logical path to list and time after m1-smoke.
  --max-list-ms <ms>             Optional maximum elapsed time for --list-path. Default: 0 (record only).
  --list-expect-error-path <dm-path>
                                  Optional logical path to list while requiring an error response.
  --list-expect-error-code <code> Expected error code for --list-expect-error-path.
  --list-expect-error-message-contains <text>
                                  Optional error message substring for --list-expect-error-path.
  --media-permission-revoked-check
                                  Revoke media read permission, then require a media ListDir permission error.
  --media-permission-revoked-during-download-check
                                  Revoke media read permission after the first proxied media download chunk,
                                  require a completed download or expected transport loss, then restore prior grants.
  --download-open-expect-error-path <dm-path>
                                  Optional source path to open as a download while requiring an error response.
  --download-open-expect-error-code <code>
                                  Expected error code for --download-open-expect-error-path.
  --download-open-expect-error-message-contains <text>
                                  Optional error message substring for --download-open-expect-error-path.
  --source-path <dm-path>        Optional logical path to download after m1-smoke.
  --destination <path>           Destination for --source-path download.
  --chunk-size-bytes <bytes>     Preferred transfer chunk size passed to harness download/upload commands.
  --resume-check                 Run a partial download, then resume it. Requires --source-path.
  --download-resume-source-mutation-check
                                  After the partial download, append one byte to a script-created app-sandbox
                                  source and require resume rejection for its changed source fingerprint.
  --download-resume-source-deletion-check
                                  After the partial download, remove a script-created app-sandbox source and
                                  require the resume attempt to return not-found.
  --download-resume-source-replacement-check
                                  After the partial download, atomically replace a script-created app-sandbox
                                  source while preserving size and mtime, then require fingerprint rejection.
  --download-retry-on-transport-loss
                                  Pass download --retry-on-transport-loss to the resume/full download command.
  --max-retry-attempts <count>    Optional extra reconnect attempts for download/upload transport-loss retry.
                                  Only applies with --*-retry-on-transport-loss or --*-retry-fault-check.
  --retry-backoff-ms <ms>         Optional base backoff for configurable recovery. Default harness value: 500.
  --download-retry-fault-check    Run the resume/full download through a local fault proxy and require recovery.
                                  Implies --download-retry-on-transport-loss.
  --dual-download-check          Open two concurrent download streams for --source-path and verify multiplexed
                                  chunks plus a responsive heartbeat. Requires --source-path.
  --mixed-transfer-check         Verify heartbeat with download/upload open, then complete both on one async
                                  session. Requires --source-path, --upload-source, and a distinct mixed target.
  --mixed-upload-destination-path <dm-path>
                                  Fresh remote upload target used only by --mixed-transfer-check.
  --cancel-check                 Open a download transfer, read one chunk, then cancel it. Requires --source-path.
  --pause-check                  Open a download transfer, read one chunk, then pause it. Requires --source-path.
  --upload-source <path>         Local file to upload after m1-smoke.
  --upload-destination-path <dm-path>
                                  Logical DroidMatch destination for --upload-source.
  --upload-resume-check          Run a partial upload, then resume it. Requires upload source/destination.
  --upload-retry-on-transport-loss
                                  Pass upload --retry-on-transport-loss to app-sandbox/SAF resume/full upload.
  --upload-retry-fault-check      Run app-sandbox/SAF resume/full upload through a local fault proxy and require recovery.
                                  Implies --upload-retry-on-transport-loss. The source must extend beyond the
                                  partial boundary plus the first 4-chunk/2 MiB upload window.
  --upload-retry-ack-loss-check   Run app-sandbox resume upload through a proxy that drops the first chunk ACK.
                                  Implies --upload-retry-on-transport-loss and requires --upload-resume-check.
                                  The source must extend beyond the partial boundary plus the first 4-chunk/2 MiB window.
  --upload-resume-unsupported-check
                                  Open a non-zero-offset upload and require unsupported-capability.
                                  Intended for fresh-only MediaStore destinations.
  --upload-partial-bytes <bytes> Bytes to upload before the intentional partial stop. Default: 1.
  --min-upload-bytes <bytes>     Require uploaded bytes to be at least this value.
  --min-upload-mib-per-second <mibps>
                                  Require measured upload throughput to be at least this value.
  --cleanup-upload-destination   Remove uploaded app-sandbox, direct-root SAF single-file, or single-file MediaStore destination on exit.
                                  Nested SAF document-token targets remain manual because their tokens are session-local.
  --require-disposable-app-sandbox-paths
                                  Refuse unless the prepared source, upload final, and destination-scoped private partial are absent.
  --partial-bytes <bytes>        Bytes to write before the intentional partial stop. Default: 1.
  --min-download-bytes <bytes>   Require full/resume download bytes to be at least this value.
  --min-download-mib-per-second <mibps>
                                  Require measured download throughput to be at least this value.
  --prepare-app-sandbox-file <name>
                                  Create an app-private zero-filled file before smoke.
  --prepare-app-sandbox-bytes <bytes>
                                  Size for --prepare-app-sandbox-file. Default: 104857600.
  --adb-baseline-download-check
                                  Time a raw adb exec-out read of the prepared app-sandbox file.
  --keep-prepared-app-sandbox-file
                                  Do not remove the prepared app sandbox file on exit.
  --device-slot <slot>           M1 matrix slot label for the result log. Default: unclassified.
  --notes <text>                 Notes to include in the result log.
  --result-log <path>            Result log path. Default: fixtures/m1-runs/<timestamp>-adb-<serial-hash>.md.
  --no-result-log                Do not write a result log.
  --open-launcher                Also launch the app through the launcher entry after install.
  --skip-build                   Use the existing debug APK instead of running check-m1-skeleton.
  -h, --help                     Show this help.

Environment:
  DROIDMATCH_ADB                 adb executable path.
  DROIDMATCH_SERIAL              Default serial.
  DROIDMATCH_ANDROID_PORT        Default remote port.
  DROIDMATCH_LOCAL_PORT          Default local port.
  DROIDMATCH_SMOKE_TIMEOUT_SECONDS
  DROIDMATCH_DEVICE_SLOT         Default matrix slot label.
  DROIDMATCH_RESULT_LOG          Default result log path.
  DROIDMATCH_RUN_NOTES           Default result log notes.
  DROIDMATCH_RESUME_PARTIAL_BYTES
  DROIDMATCH_UPLOAD_PARTIAL_BYTES
  DROIDMATCH_MAX_RETRY_ATTEMPTS
  DROIDMATCH_RETRY_BACKOFF_MS
  DROIDMATCH_MIN_DOWNLOAD_BYTES
  DROIDMATCH_MIN_DOWNLOAD_MIB_PER_SECOND
  DROIDMATCH_MIN_UPLOAD_BYTES
  DROIDMATCH_MIN_UPLOAD_MIB_PER_SECOND
  DROIDMATCH_TRANSFER_CHUNK_SIZE_BYTES
  DROIDMATCH_UPLOAD_SOURCE_FILE
  DROIDMATCH_UPLOAD_DESTINATION_PATH
  DROIDMATCH_PREPARE_APP_SANDBOX_FILE
  DROIDMATCH_PREPARE_APP_SANDBOX_BYTES
  DROIDMATCH_ADB_BASELINE_DOWNLOAD_CHECK
  DROIDMATCH_DOWNLOAD_RESUME_SOURCE_MUTATION_CHECK
  DROIDMATCH_DOWNLOAD_RESUME_SOURCE_DELETION_CHECK
  DROIDMATCH_DOWNLOAD_RESUME_SOURCE_REPLACEMENT_CHECK
  DROIDMATCH_DUAL_DOWNLOAD_CHECK
  DROIDMATCH_MIXED_TRANSFER_CHECK
  DROIDMATCH_MIXED_UPLOAD_DESTINATION_PATH
  DROIDMATCH_HANDSHAKE_ATTEMPTS
  DROIDMATCH_MIN_HANDSHAKE_PASSES
  DROIDMATCH_LIST_PATH
  DROIDMATCH_MAX_LIST_MS
  DROIDMATCH_LIST_EXPECT_ERROR_PATH
  DROIDMATCH_LIST_EXPECT_ERROR_CODE
  DROIDMATCH_LIST_EXPECT_ERROR_MESSAGE_CONTAINS
  DROIDMATCH_MEDIA_PERMISSION_REVOKED_CHECK
  DROIDMATCH_MEDIA_PERMISSION_REVOKED_DURING_DOWNLOAD_CHECK
  DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_PATH
  DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_CODE
  DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_MESSAGE_CONTAINS
USAGE
}
