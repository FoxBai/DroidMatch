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
  printf 'Checking Android Gradle debug APK build and lint...\n'
  (
    cd android
    ANDROID_HOME="${android_sdk}" ANDROID_SDK_ROOT="${android_sdk}" \
      "${gradle_bin}" --no-daemon :app:assembleDebug :app:lintDebug
  )
else
  printf 'Gradle not found; commit android/gradlew, install Gradle 8.13, or set DROIDMATCH_GRADLE.\n' >&2
  exit 1
fi

printf 'M1 skeleton check passed.\n'
