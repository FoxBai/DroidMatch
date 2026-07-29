#!/usr/bin/env bash
# Sourced generation of the self-contained permission-revoke hook.

prepare_media_permission_revoke_during_download_check() {
  [[ "${media_permission_revoked_during_download_check}" -eq 1 ]] || return 0

  local before_snapshot
  capture_media_permission_restore_state
  before_snapshot="$(media_permission_snapshot)" || {
    fail_with_log "media permission revoke guard" \
      "Could not revalidate the media-permission baseline before preparing the hook."
  }
  media_permission_snapshot_matches_restore_state "${before_snapshot}" || {
    fail_with_log "media permission revoke guard" \
      "Media-permission state changed after baseline capture; no hook was prepared."
  }
  media_permission_mutation_output="$(
    {
      printf 'before revoke during download: %s\n' \
        "$(media_permission_snapshot_state_line "${before_snapshot}")"
      printf 'revoke trigger: after first proxied media download chunk\n'
    }
  )"

  media_permission_revoke_hook_script="$(mktemp /tmp/droidmatch-media-permission-revoke.XXXXXX)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'adb_bin=%q\n' "${adb_bin}"
    printf 'serial=%q\n' "${serial}"
    printf 'expected_user=%q\n' "${media_permission_restore_user_id}"
    printf 'expected_sdk=%q\n' "${sdk_int}"
    cat <<'HOOK'
run_adb_shell_record() {
  local status
  set +e
  "${adb_bin}" -s "${serial}" shell "$@" >/dev/null 2>&1
  status=$?
  set -e
  # This fresh hook emits aggregate status only and never private parameters.
  printf 'adb permission command status=%s\n' "${status}"
  return "${status}"
}

revoke_permission() {
  local permission="$1" sdk current_user
  sdk="$("${adb_bin}" -s "${serial}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' | tail -1)"
  current_user="$("${adb_bin}" -s "${serial}" shell am get-current-user 2>/dev/null | tr -d '\r' | tail -1)"
  if ! [[ "${sdk}" =~ ^[0-9]+$ && "${sdk}" == "${expected_sdk}" \
      && "${current_user}" =~ ^[0-9]+$ \
      && "${current_user}" == "${expected_user}" ]]; then
    printf '%s\n' 'adb permission mutation context changed; hook refused'
    return 2
  fi
  run_adb_shell_record pm revoke --user "${expected_user}" \
    app.droidmatch "${permission}"
}

if [[ "${expected_sdk}" =~ ^[0-9]+$ && "${expected_sdk}" -ge 34 ]]; then
  revoke_permission android.permission.READ_MEDIA_VISUAL_USER_SELECTED
  revoke_permission android.permission.READ_MEDIA_IMAGES
  revoke_permission android.permission.READ_MEDIA_VIDEO
elif [[ "${expected_sdk}" == 33 ]]; then
  revoke_permission android.permission.READ_MEDIA_IMAGES
  revoke_permission android.permission.READ_MEDIA_VIDEO
elif [[ "${expected_sdk}" =~ ^(2[6-9]|3[0-2])$ ]]; then
  revoke_permission android.permission.READ_EXTERNAL_STORAGE
else
  printf '%s\n' 'unsupported SDK; hook refused'
  exit 2
fi
HOOK
  } > "${media_permission_revoke_hook_script}"
  chmod +x "${media_permission_revoke_hook_script}"
}
