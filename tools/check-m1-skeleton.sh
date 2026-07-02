#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

printf 'Checking Mac Swift harness...\n'
swift test --package-path mac

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
if [[ ! -d "${android_sdk}/platforms" ]]; then
  printf 'Android SDK platforms not found under %s\n' "${android_sdk}" >&2
  exit 1
fi

gradle_bin="${DROIDMATCH_GRADLE:-}"
if [[ -z "${gradle_bin}" && -x android/gradlew ]]; then
  gradle_bin="./gradlew"
elif [[ -z "${gradle_bin}" ]] && command -v gradle >/dev/null 2>&1; then
  gradle_bin="gradle"
fi

if [[ -n "${gradle_bin}" ]]; then
  printf 'Checking Android Gradle unit tests, debug APK build, and lint...\n'
  gradle_tasks=(:app:testDebugUnitTest :app:assembleDebug :app:lintDebug)
  gradle_args=(--no-daemon)
  if [[ "${DROIDMATCH_GRADLE_OFFLINE:-0}" == "1" ]]; then
    gradle_args+=(--offline)
  fi

  if ! (
    cd android
    ANDROID_HOME="${android_sdk}" ANDROID_SDK_ROOT="${android_sdk}" \
      "${gradle_bin}" "${gradle_args[@]}" "${gradle_tasks[@]}"
  ); then
    if [[ "${DROIDMATCH_GRADLE_OFFLINE:-0}" == "1" ]]; then
      exit 1
    fi
    printf 'Android Gradle online run failed; retrying with --offline using local caches.\n' >&2
    (
      cd android
      ANDROID_HOME="${android_sdk}" ANDROID_SDK_ROOT="${android_sdk}" \
      "${gradle_bin}" --no-daemon --offline "${gradle_tasks[@]}"
    )
  fi

  merged_manifest="$(find android/app/build/intermediates/merged_manifests/debug -name AndroidManifest.xml -print -quit)"
  if [[ -z "${merged_manifest}" ]]; then
    printf 'Debug merged manifest was not generated.\n' >&2
    exit 1
  fi
  if ! grep -q 'android:name="app.droidmatch.m1.DiagnosticsActivity"' "${merged_manifest}" \
      || ! grep -q 'android.intent.action.MAIN' "${merged_manifest}" \
      || ! grep -q 'android.intent.category.LAUNCHER' "${merged_manifest}"; then
    printf 'Debug APK must expose DroidMatch DiagnosticsActivity as a launcher entry.\n' >&2
    exit 1
  fi
  debug_apk="android/app/build/outputs/apk/debug/app-debug.apk"
  aapt_bin="$(find "${android_sdk}/build-tools" -name aapt -type f -print | sort | tail -1)"
  if [[ ! -x "${aapt_bin}" ]]; then
    printf 'Android SDK aapt was not found under %s/build-tools.\n' "${android_sdk}" >&2
    exit 1
  fi
  if ! "${aapt_bin}" dump badging "${debug_apk}" \
      | grep -q "launchable-activity: name='app.droidmatch.m1.DiagnosticsActivity'"; then
    printf 'Debug APK badging does not expose DroidMatch DiagnosticsActivity as launchable.\n' >&2
    exit 1
  fi
else
  printf 'Gradle not found; commit android/gradlew, install Gradle 8.13, or set DROIDMATCH_GRADLE.\n' >&2
  exit 1
fi

printf 'M1 skeleton check passed.\n'
