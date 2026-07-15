#!/usr/bin/env bash

# Publish one already-rendered product USB fixture without following either the
# staged path or a competing result symlink. 中文：只发布已生成的产品 USB fixture，
# staged/result 任一路径为符号链接或被并发占用时都必须失败。
publish_product_usb_staged_log() {
  local staged_log="$1" result_log="$2" checker="$3"

  [[ -f "${staged_log}" && ! -L "${staged_log}" ]] || return 1
  [[ ! -e "${result_log}" && ! -L "${result_log}" ]] || return 1
  bash "${checker}" --log "${staged_log}" >/dev/null 2>&1 || return 1

  # `-n` prevents a destination symlink to a directory from being followed.
  # The hard link is the no-clobber commit; the staged link must then disappear
  # before the caller is allowed to report success.
  ln -n "${staged_log}" "${result_log}" 2>/dev/null || return 1
  [[ -f "${result_log}" && ! -L "${result_log}" ]] || return 1
  rm -f "${staged_log}" || return 1
  [[ ! -e "${staged_log}" && ! -L "${staged_log}" ]] || return 1
}
