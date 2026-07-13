#!/usr/bin/env bash

# English: Keep evidence redaction in one shell-safe boundary. The smoke script
# sets DROIDMATCH_REDACT_* values before calling this function; callers never
# need to interpolate a user path into a regular expression themselves.
# 中文：把证据脱敏集中在一个 shell 安全边界；smoke 脚本调用前设置
# DROIDMATCH_REDACT_*，调用方无需自行把用户路径插入正则表达式。

redact_m1_output() {
  DROIDMATCH_REDACT_SERIAL="${DROIDMATCH_REDACT_SERIAL:-}" \
    DROIDMATCH_REDACT_SERIAL_TAG="${DROIDMATCH_REDACT_SERIAL_TAG:-}" \
    DROIDMATCH_REDACT_DOWNLOAD_DESTINATION="${DROIDMATCH_REDACT_DOWNLOAD_DESTINATION:-}" \
    DROIDMATCH_REDACT_UPLOAD_SOURCE="${DROIDMATCH_REDACT_UPLOAD_SOURCE:-}" \
    DROIDMATCH_REDACT_RESULT_LOG="${DROIDMATCH_REDACT_RESULT_LOG:-}" \
    DROIDMATCH_REDACT_REPO_ROOT="${DROIDMATCH_REDACT_REPO_ROOT:-}" \
    DROIDMATCH_REDACT_ADB_PATH="${DROIDMATCH_REDACT_ADB_PATH:-}" \
    DROIDMATCH_REDACT_NOTES="${DROIDMATCH_REDACT_NOTES:-}" \
    DROIDMATCH_REDACT_NAME="${DROIDMATCH_REDACT_NAME:-}" \
    DROIDMATCH_REDACT_LIST_PATH="${DROIDMATCH_REDACT_LIST_PATH:-}" \
    DROIDMATCH_REDACT_LIST_ERROR_PATH="${DROIDMATCH_REDACT_LIST_ERROR_PATH:-}" \
    DROIDMATCH_REDACT_DOWNLOAD_SOURCE_PATH="${DROIDMATCH_REDACT_DOWNLOAD_SOURCE_PATH:-}" \
    DROIDMATCH_REDACT_DOWNLOAD_ERROR_PATH="${DROIDMATCH_REDACT_DOWNLOAD_ERROR_PATH:-}" \
    DROIDMATCH_REDACT_UPLOAD_DESTINATION_PATH="${DROIDMATCH_REDACT_UPLOAD_DESTINATION_PATH:-}" \
    DROIDMATCH_REDACT_MIXED_DESTINATION_PATH="${DROIDMATCH_REDACT_MIXED_DESTINATION_PATH:-}" \
    DROIDMATCH_REDACT_PREPARED_SOURCE_PATH="${DROIDMATCH_REDACT_PREPARED_SOURCE_PATH:-}" \
    perl -0pe '
      sub replace_value {
        my ($value, $replacement) = @_;
        return if !defined($value) || $value eq "";
        # Avoid replacing a short user name inside an unrelated word while
        # still matching it next to shell/Markdown punctuation.
        s{(?<![A-Za-z0-9._-])\Q$value\E(?![A-Za-z0-9._-])}{$replacement}g;
      }

      replace_value($ENV{DROIDMATCH_REDACT_SERIAL},
        "<serial-redacted:$ENV{DROIDMATCH_REDACT_SERIAL_TAG}>");
      replace_value($ENV{DROIDMATCH_REDACT_DOWNLOAD_DESTINATION}, "<download-destination>");
      replace_value($ENV{DROIDMATCH_REDACT_UPLOAD_SOURCE}, "<upload-source>");
      replace_value($ENV{DROIDMATCH_REDACT_RESULT_LOG}, "<result-log-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_REPO_ROOT}, "<repo-path-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_ADB_PATH}, "<adb-path-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_NOTES}, "<notes-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_LIST_PATH}, "<dm-path-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_LIST_ERROR_PATH}, "<dm-path-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_DOWNLOAD_SOURCE_PATH}, "<dm-path-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_DOWNLOAD_ERROR_PATH}, "<dm-path-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_UPLOAD_DESTINATION_PATH}, "<dm-path-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_MIXED_DESTINATION_PATH}, "<dm-path-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_PREPARED_SOURCE_PATH}, "<dm-path-redacted>");
      replace_value($ENV{DROIDMATCH_REDACT_NAME}, "<name-redacted>");
    '
}
