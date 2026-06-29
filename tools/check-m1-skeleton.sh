#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

printf 'Checking Mac Swift harness...\n'
swift test --package-path mac

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
android_jar="$(
  find "${android_sdk}/platforms" -maxdepth 2 -path '*/android-[0-9]*/android.jar' 2>/dev/null \
    | awk -F'android-' '{split($2, parts, "/"); print parts[1] " " $0}' \
    | sort -n \
    | awk '{$1=""; sub(/^ /, ""); print}' \
    | tail -1
)"

if [[ -z "${android_jar}" ]]; then
  printf 'android.jar not found under %s\n' "${android_sdk}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

printf 'Checking Android service skeleton with %s...\n' "${android_jar}"
find android/app/src/main/java -name '*.java' -print0 \
  | xargs -0 javac -source 11 -target 11 -Xlint:all -Xlint:-options -cp "${android_jar}" -d "${tmp_dir}/android-classes"

printf 'M1 skeleton check passed.\n'
