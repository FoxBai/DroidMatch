#!/usr/bin/env bash

# Shared destination identity for Android's private app-sandbox upload staging.
# Keep this byte-for-byte aligned with AndroidAppSandboxCatalog.uploadDestinationKey.
# 中文：Android 与真机清理脚本必须共享完全一致的 destination 摘要输入。
droidmatch_app_sandbox_upload_destination_key() {
  local relative_path="$1"
  {
    printf '%s' 'app-sandbox-upload-destination-v1'
    printf '\0'
    printf '%s' "${relative_path}"
  } | shasum -a 256 | awk '{ print $1 }'
}

droidmatch_app_sandbox_upload_staging_directory() {
  printf '%s\n' 'files/.droidmatch-sandbox.droidmatch-upload-staging'
}

droidmatch_app_sandbox_upload_staging_glob() {
  local relative_path="$1" destination_key staging_directory
  destination_key="$(droidmatch_app_sandbox_upload_destination_key "${relative_path}")" \
    || return 1
  [[ "${destination_key}" =~ ^[0-9a-f]{64}$ ]] || return 1
  staging_directory="$(droidmatch_app_sandbox_upload_staging_directory)" || return 1
  printf '%s/%s.*.part\n' "${staging_directory}" "${destination_key}"
}
