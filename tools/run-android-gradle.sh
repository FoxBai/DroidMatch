#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
source tools/lib/android-environment.sh

if [[ "$#" -eq 0 ]]; then
  printf 'Usage: tools/run-android-gradle.sh <gradle-task> [...]\n' >&2
  printf '中文：用法：tools/run-android-gradle.sh <Gradle 任务> [...]\n' >&2
  exit 2
fi

# The preflight validates the same candidates selected below. It runs in a
# child process, so this wrapper deliberately republishes the resolved JDK and
# SDK into the Gradle process instead of relying on child exports.
bash tools/check-env.sh --android

if ! droidmatch_jdk_home="$(droidmatch_find_jdk17_home)"; then
  printf 'JDK 17 disappeared after Android environment validation.\n' >&2
  printf '中文：Android 环境验证后无法再解析 JDK 17。\n' >&2
  exit 1
fi

droidmatch_android_sdk="$(droidmatch_find_android_sdk)"
export JAVA_HOME="${droidmatch_jdk_home}"
export PATH="${JAVA_HOME}/bin:${PATH}"
export ANDROID_HOME="${droidmatch_android_sdk}"
export ANDROID_SDK_ROOT="${droidmatch_android_sdk}"

if [[ -n "${DROIDMATCH_GRADLE:-}" ]]; then
  droidmatch_gradle="${DROIDMATCH_GRADLE}"
  if [[ "${droidmatch_gradle}" != /* ]]; then
    droidmatch_gradle="${repo_root}/${droidmatch_gradle}"
  fi
elif [[ -x "${repo_root}/android/gradlew" ]]; then
  droidmatch_gradle="${repo_root}/android/gradlew"
else
  droidmatch_gradle="$(command -v gradle)"
fi

cd android
exec "${droidmatch_gradle}" --no-daemon "$@"
