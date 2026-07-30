#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-android-gradle.XXXXXX")"
fixture_root="$(cd "${fixture_root}" && pwd -P)"
trap 'rm -rf "${fixture_root}"' EXIT

mkdir -p \
  "${fixture_root}/tools/lib" \
  "${fixture_root}/android" \
  "${fixture_root}/mock-jdk-17/bin" \
  "${fixture_root}/mock-jdk-21/bin" \
  "${fixture_root}/mock-sdk/platforms/android-36" \
  "${fixture_root}/mock-sdk/build-tools/36.0.0" \
  "${fixture_root}/mock"
cp tools/check-env.sh tools/run-android-gradle.sh "${fixture_root}/tools/"
cp tools/lib/android-environment.sh "${fixture_root}/tools/lib/"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ -z "${JAVA_TOOL_OPTIONS:-}" ]] || printf '\''Picked up JAVA_TOOL_OPTIONS: %s\n'\'' "${JAVA_TOOL_OPTIONS}" >&2' \
  '[[ -z "${_JAVA_OPTIONS:-}" ]] || printf '\''Picked up _JAVA_OPTIONS: %s\n'\'' "${_JAVA_OPTIONS}" >&2' \
  'printf '\''openjdk version "17.0.1"\n'\'' >&2' \
  > "${fixture_root}/mock-jdk-17/bin/java"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ -z "${JAVA_TOOL_OPTIONS:-}" ]] || printf '\''Picked up JAVA_TOOL_OPTIONS: %s\n'\'' "${JAVA_TOOL_OPTIONS}" >&2' \
  '[[ -z "${_JAVA_OPTIONS:-}" ]] || printf '\''Picked up _JAVA_OPTIONS: %s\n'\'' "${_JAVA_OPTIONS}" >&2' \
  'printf '\''javac 17.0.1\n'\''' \
  > "${fixture_root}/mock-jdk-17/bin/javac"
printf '#!/usr/bin/env bash\nprintf '\''openjdk version "21.0.1"\\n'\'' >&2\n' \
  > "${fixture_root}/mock-jdk-21/bin/java"
printf '#!/usr/bin/env bash\nprintf '\''javac 21.0.1\\n'\''\n' \
  > "${fixture_root}/mock-jdk-21/bin/javac"
printf '#!/usr/bin/env bash\nexit 0\n' \
  > "${fixture_root}/mock-sdk/build-tools/36.0.0/aapt"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''JAVA_HOME=%s\nANDROID_HOME=%s\nANDROID_SDK_ROOT=%s\nPWD=%s\nARGS=%s\n'\'' \' \
  '  "${JAVA_HOME}" "${ANDROID_HOME}" "${ANDROID_SDK_ROOT}" "${PWD}" "$*" \' \
  '  > "${DROIDMATCH_TEST_RESULT}"' \
  > "${fixture_root}/mock/gradle"
chmod 0755 \
  "${fixture_root}/tools/check-env.sh" \
  "${fixture_root}/tools/run-android-gradle.sh" \
  "${fixture_root}/mock-jdk-17/bin/java" \
  "${fixture_root}/mock-jdk-17/bin/javac" \
  "${fixture_root}/mock-jdk-21/bin/java" \
  "${fixture_root}/mock-jdk-21/bin/javac" \
  "${fixture_root}/mock-sdk/build-tools/36.0.0/aapt" \
  "${fixture_root}/mock/gradle"

if JAVA_HOME="${fixture_root}/mock-jdk-21" bash -c \
  'source "$1"; droidmatch_is_jdk17_home "${JAVA_HOME}"' \
  _ "${fixture_root}/tools/lib/android-environment.sh"; then
  printf 'JDK 21 was incorrectly accepted as JDK 17.\n' >&2
  exit 1
fi

set +e
bash "${fixture_root}/tools/run-android-gradle.sh" >/dev/null 2>&1
no_arguments_status=$?
set -e
if [[ "${no_arguments_status}" -ne 2 ]]; then
  printf 'Android Gradle wrapper accepted an empty task list.\n' >&2
  exit 1
fi

result_file="${fixture_root}/gradle-environment.txt"
wrapper_log="${fixture_root}/wrapper.log"
(
  cd "${fixture_root}"
  JAVA_HOME="mock-jdk-17" \
  ANDROID_HOME="mock-sdk" \
  ANDROID_SDK_ROOT="${fixture_root}/ignored-sdk" \
  DROIDMATCH_GRADLE="mock/gradle" \
  DROIDMATCH_TEST_RESULT="${result_file}" \
  JAVA_TOOL_OPTIONS="-Ddroidmatch.review=true" \
  _JAVA_OPTIONS="-Ddroidmatch.review.also=true" \
    bash "${fixture_root}/tools/run-android-gradle.sh" \
      :app:assembleDebug --stacktrace >"${wrapper_log}" 2>&1
)

if grep -Fq "${fixture_root}" "${wrapper_log}"; then
  printf 'Android Gradle wrapper leaked a private absolute path.\n' >&2
  exit 1
fi
if grep -Eq 'JAVA_TOOL_OPTIONS|_JAVA_OPTIONS' "${wrapper_log}"; then
  printf 'Android Gradle wrapper leaked JVM option contents.\n' >&2
  exit 1
fi

grep -Fqx "JAVA_HOME=${fixture_root}/mock-jdk-17" "${result_file}"
grep -Fqx "ANDROID_HOME=${fixture_root}/mock-sdk" "${result_file}"
grep -Fqx "ANDROID_SDK_ROOT=${fixture_root}/mock-sdk" "${result_file}"
grep -Fqx "PWD=${fixture_root}/android" "${result_file}"
grep -Fqx 'ARGS=--no-daemon :app:assembleDebug --stacktrace' "${result_file}"

printf 'Android Gradle environment wrapper regressions passed.\n'
printf '中文：Android Gradle 环境入口离线回归通过。\n'
