#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

if [[ "${DROIDMATCH_SKIP_SWIFT:-0}" == "1" ]]; then
  printf 'Skipping Mac Swift harness because DROIDMATCH_SKIP_SWIFT=1.\n'
else
  # English: fail fast with actionable toolchain guidance before SwiftPM's
  # longer build output. 中文：先做可读的 toolchain 诊断，再进入较长的 SwiftPM 编译。
  bash tools/check-env.sh --swift
  printf 'Checking Mac Swift harness...\n'
  bash tools/run-swift-tests.sh
fi

printf 'Checking device-smoke script syntax and documented opt-in probes...\n'
bash -n tools/run-m1-device-smoke.sh
device_smoke_help="$(bash tools/run-m1-device-smoke.sh --help)"
for required_probe in --dual-download-check --mixed-transfer-check --mixed-upload-destination-path; do
  if ! grep -q -- "${required_probe}" <<<"${device_smoke_help}"; then
    printf 'Device-smoke help is missing required probe: %s\n' "${required_probe}" >&2
    printf '中文：真机 smoke 帮助缺少必需探针：%s\n' "${required_probe}" >&2
    exit 1
  fi
done

android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
if [[ ! -d "${android_sdk}/platforms" ]]; then
  printf 'Android SDK platforms not found under %s\n' "${android_sdk}" >&2
  printf '中文：未在上述路径找到 Android SDK platforms；请安装 platform 35 或设置 ANDROID_HOME。\n' >&2
  exit 1
fi

# English: Homebrew openjdk@17 is keg-only and may not be visible through
# /usr/bin/java in non-interactive shells. 中文：Homebrew openjdk@17 是 keg-only，
# 非交互 shell 里 /usr/bin/java 可能找不到它，所以这里显式导出。
if [[ -z "${JAVA_HOME:-}" \
    && -x /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/java \
    && -x /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin/javac ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
  export PATH="${JAVA_HOME}/bin:${PATH}"
fi

gradle_bin="${DROIDMATCH_GRADLE:-}"
if [[ -z "${gradle_bin}" && -x android/gradlew ]]; then
  gradle_bin="./gradlew"
elif [[ -z "${gradle_bin}" ]] && command -v gradle >/dev/null 2>&1; then
  gradle_bin="gradle"
fi

if [[ -n "${gradle_bin}" ]]; then
  # English: Java/SDK issues are environment problems, not Android source
  # failures. 中文：Java/SDK 缺失属于环境问题，不应被误读成 Android 代码失败。
  bash tools/check-env.sh --android
  printf 'Checking Android Gradle unit tests, debug APKs, instrumentation-test compilation, and lint...\n'
  # The androidTest APK is compiled in CI so Keystore instrumentation tests
  # cannot silently rot. It is not executed without an explicitly selected
  # emulator/device; physical-device evidence remains a manual matrix action.
  gradle_tasks=(:app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest :app:lintDebug)
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
    printf '中文：debug 合并后的 AndroidManifest.xml 未生成。\n' >&2
    exit 1
  fi
  if ! grep -q 'android:name="app.droidmatch.m1.DiagnosticsActivity"' "${merged_manifest}" \
      || ! grep -q 'android.intent.action.MAIN' "${merged_manifest}" \
      || ! grep -q 'android.intent.category.LAUNCHER' "${merged_manifest}"; then
    printf 'Debug APK must expose DroidMatch DiagnosticsActivity as a launcher entry.\n' >&2
    printf '中文：debug APK 必须把 DroidMatch DiagnosticsActivity 暴露为启动器入口。\n' >&2
    exit 1
  fi
  debug_apk="android/app/build/outputs/apk/debug/app-debug.apk"
  aapt_bin="$(find "${android_sdk}/build-tools" -name aapt -type f -print | sort | tail -1)"
  if [[ ! -x "${aapt_bin}" ]]; then
    printf 'Android SDK aapt was not found under %s/build-tools.\n' "${android_sdk}" >&2
    printf '中文：未在 Android SDK build-tools 下找到 aapt。\n' >&2
    exit 1
  fi
  if ! "${aapt_bin}" dump badging "${debug_apk}" \
      | grep -q "launchable-activity: name='app.droidmatch.m1.DiagnosticsActivity'"; then
    printf 'Debug APK badging does not expose DroidMatch DiagnosticsActivity as launchable.\n' >&2
    printf '中文：debug APK badging 未显示 DiagnosticsActivity 为可启动 Activity。\n' >&2
    exit 1
  fi
else
  printf 'Gradle not found; commit android/gradlew, install Gradle 8.13, or set DROIDMATCH_GRADLE.\n' >&2
  printf '中文：未找到 Gradle；请使用 android/gradlew、安装 Gradle 8.13，或设置 DROIDMATCH_GRADLE。\n' >&2
  exit 1
fi

printf 'M1 skeleton check passed.\n'
