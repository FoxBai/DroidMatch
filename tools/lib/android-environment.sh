#!/usr/bin/env bash

# Shared Android/JDK discovery for preflight and the Gradle launcher. This file
# is sourced; callers own shell options and error reporting.

droidmatch_is_jdk17_home() {
  local candidate="$1"
  local java_version
  local javac_version
  [[ -x "${candidate}/bin/java" && -x "${candidate}/bin/javac" ]] || return 1
  java_version="$("${candidate}/bin/java" -version 2>&1 | head -c 4096)" \
    || return 1
  javac_version="$("${candidate}/bin/javac" -version 2>&1 | head -c 4096)" \
    || return 1
  grep -Eq '^(openjdk |java )?version "17([.+-]|")' <<<"${java_version}" \
    && grep -Eq '^javac[[:space:]]+17([.+-]|$)' <<<"${javac_version}"
}

droidmatch_find_jdk17_home() {
  local candidate
  if [[ -n "${JAVA_HOME:-}" ]]; then
    candidate="${JAVA_HOME}"
    if [[ "${candidate}" != /* ]]; then
      candidate="$(cd "${candidate}" 2>/dev/null && pwd -P)" || candidate=""
    fi
    if [[ -n "${candidate}" ]] && droidmatch_is_jdk17_home "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  fi
  for candidate in \
    /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home; do
    if droidmatch_is_jdk17_home "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  if [[ -x /usr/libexec/java_home ]]; then
    candidate="$(/usr/libexec/java_home -v 17 2>/dev/null)" || return 1
    if droidmatch_is_jdk17_home "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  fi
  return 1
}

droidmatch_find_android_sdk() {
  local candidate
  candidate="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
  if [[ "${candidate}" != /* ]]; then
    if [[ -d "${candidate}" ]]; then
      candidate="$(cd "${candidate}" && pwd -P)"
    else
      candidate="${PWD}/${candidate}"
    fi
  fi
  printf '%s' "${candidate}"
}
