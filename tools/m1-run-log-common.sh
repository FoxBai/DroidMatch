#!/usr/bin/env bash

# Shared fail-closed text and digest primitives for M1 evidence validators.
# 中文：M1 证据校验器共用的 fail-closed 文本扫描与摘要原语。

grep_count() {
  local output status
  if output="$(grep "$@" 2>/dev/null)"; then
    printf '%s' "${output}"
    return 0
  else
    status=$?
  fi
  if [[ "${status}" -eq 1 ]]; then
    printf '%s' "${output}"
    return 0
  fi
  return 2
}

grep_match() {
  local status
  if grep "$@" >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi
  [[ "${status}" -eq 1 ]] && return 1
  return 2
}

profile_value() {
  local log="$1" field="$2" count value
  count="$(grep_count -c "^${field}:" "${log}")" || return 1
  if [[ "${count}" -ne 1 ]]; then
    printf 'throughput evidence field must appear exactly once (%s): %s\n' \
      "${field}" "${log}" >&2
    return 1
  fi
  value="$(sed -n "s/^${field}: //p" "${log}" 2>/dev/null)" || return 1
  printf '%s\n' "${value}"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{ print $1 }'
  else
    return 1
  fi
}

section_has_pattern() {
  local log="$1" heading="$2" pattern="$3"
  awk -v heading="${heading}" -v pattern="${pattern}" '
    function fence_run(line, character, value) {
      value = line
      if (character == "`") sub(/[^`].*$/, "", value)
      else sub(/[^~].*$/, "", value)
      return length(value)
    }
    {
      line = $0
      sub(/^ {0,3}/, "", line)
      character = substr(line, 1, 1)
      run = 0
      if (character == "`" || character == "~") {
        run = fence_run(line, character)
      }
      rest = substr(line, run + 1)
      if (in_fence) {
        if (character == fence_character && run >= fence_length \
            && rest ~ /^[ \t]*$/) {
          in_fence = 0
          if (active && body) { closed = 1; exit }
        } else if (active && body && $0 ~ pattern) {
          found = 1
        }
        next
      }
      if (run >= 3 && (character == "~" || rest !~ /`/)) {
        in_fence = 1
        fence_character = character
        fence_length = run
        if (active) body = 1
        next
      }
      if ($0 == heading) { active = 1; next }
      if (active && /^## /) exit
    }
    END { exit !(active && body && closed && found) }
  ' "${log}"
}
