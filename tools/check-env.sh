#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
source tools/lib/android-environment.sh

usage() {
  cat <<'USAGE'
Usage: tools/check-env.sh [--all] [--proto] [--swift] [--android]

Checks local or CI prerequisites before running DroidMatch gates.
在运行 DroidMatch gate 前检查本机或 CI 依赖。

Options:
  --all       Check all prerequisites. / 检查全部依赖。
  --proto    Check protoc for schema compilation. / 检查 protobuf 编译器。
  --swift    Check SwiftPM and Swift Testing support. / 检查 SwiftPM 和 Swift Testing。
  --android  Check Java, Android SDK, and Gradle wrapper. / 检查 Java、Android SDK 和 Gradle。
  --help     Show this help. / 显示帮助。
USAGE
}

want_proto=0
want_swift=0
want_android=0

if [[ "$#" -eq 0 ]]; then
  want_proto=1
  want_swift=1
  want_android=1
fi

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --all)
      want_proto=1
      want_swift=1
      want_android=1
      ;;
    --proto)
      want_proto=1
      ;;
    --swift)
      want_swift=1
      ;;
    --android)
      want_android=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

find_protoc() {
  if command -v protoc >/dev/null 2>&1; then
    printf 'protoc'
  elif [[ -x "${HOME}/.local/bin/protoc" ]]; then
    printf '%s/.local/bin/protoc' "${HOME}"
  else
    return 1
  fi
}

check_proto() {
  local protoc_bin
  if ! protoc_bin="$(find_protoc)"; then
    fail "protoc not found. English: install protobuf-compiler or add protoc to PATH. 中文：请安装 protobuf-compiler，或把 protoc 加到 PATH。"
  fi
  printf 'Proto prerequisite ok: %s\n' "$("${protoc_bin}" --version)"
}

check_swift() {
  command -v swift >/dev/null 2>&1 \
    || fail "swift not found. English: install/select Xcode 16+ or a compatible Swift toolchain. 中文：请安装/切换到 Xcode 16+ 或兼容 Swift 工具链。"
  command -v swiftc >/dev/null 2>&1 \
    || fail "swiftc not found. English: install/select Xcode 16+ or a compatible Swift toolchain. 中文：请安装/切换到 Xcode 16+ 或兼容 Swift 工具链。"

  swift --version | sed -n '1p'
  bash tools/run-swift-tests.sh --probe-only
}

check_android() {
  local jdk_home
  if ! jdk_home="$(droidmatch_find_jdk17_home)"; then
    fail "JDK 17 not found. English: install JDK 17 and set JAVA_HOME if needed. 中文：未找到 JDK 17；请安装 JDK 17，必要时设置 JAVA_HOME。"
  fi
  export JAVA_HOME="${jdk_home}"
  export PATH="${JAVA_HOME}/bin:${PATH}"

  printf 'Java prerequisite ok: JDK 17 selected.\n'

  local android_sdk
  android_sdk="$(droidmatch_find_android_sdk)"
  [[ -d "${android_sdk}/platforms/android-36" ]] \
    || fail "Android SDK platform 36 not found in the configured SDK. English: install platforms;android-36 or set ANDROID_HOME. 中文：配置的 SDK 中未找到 Android platform 36；请安装 platforms;android-36，或设置 ANDROID_HOME。"
  [[ -x "${android_sdk}/build-tools/36.0.0/aapt" ]] \
    || fail "Android Build Tools 36.0.0 not found in the configured SDK. English: install build-tools;36.0.0 or set ANDROID_HOME. 中文：配置的 SDK 中未找到 Android Build Tools 36.0.0；请安装 build-tools;36.0.0，或设置 ANDROID_HOME。"
  printf 'Android SDK prerequisite ok: platform 36 and Build Tools 36.0.0.\n'

  if [[ -n "${DROIDMATCH_GRADLE:-}" ]]; then
    [[ -x "${DROIDMATCH_GRADLE}" ]] \
      || fail "DROIDMATCH_GRADLE is set but is not executable. 中文：DROIDMATCH_GRADLE 已设置，但该路径不可执行。"
    printf 'Gradle prerequisite ok: configured DROIDMATCH_GRADLE executable.\n'
  elif [[ -x android/gradlew ]]; then
    printf 'Gradle prerequisite ok: android/gradlew\n'
  elif [[ "${DROIDMATCH_REQUIRE_GRADLE:-0}" == "1" ]]; then
    fail "Checked-in Gradle wrapper required. English: restore android/gradlew or set DROIDMATCH_GRADLE explicitly. 中文：当前要求使用可复现的 Gradle 路径；请恢复 android/gradlew，或显式设置 DROIDMATCH_GRADLE。"
  elif command -v gradle >/dev/null 2>&1; then
    printf 'Gradle prerequisite ok: system Gradle executable.\n'
  else
    fail "Gradle not found. English: use the checked-in android/gradlew or set DROIDMATCH_GRADLE. 中文：请使用仓库内 android/gradlew，或设置 DROIDMATCH_GRADLE。"
  fi
}

if [[ "${want_proto}" -eq 1 ]]; then
  check_proto
fi
if [[ "${want_swift}" -eq 1 ]]; then
  check_swift
fi
if [[ "${want_android}" -eq 1 ]]; then
  check_android
fi

printf 'Environment check passed.\n'
