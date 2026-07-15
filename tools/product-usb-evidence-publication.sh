#!/usr/bin/env bash

# Publish one already-rendered `.commit` companion from its pinned descriptor.
# Both names remain after success, and production never unlinks either pathname.
# 中文：从已固定描述符发布 `.commit` 伴随文件；成功后两个名称都保留，
# 生产路径不会 unlink 任何一个。
readonly PRODUCT_USB_PUBLICATION_UNCERTAIN_STATUS=3

create_product_usb_commit_companion() {
  local result_log="$1" checker="$2"
  local helper_dir

  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  python3 "${helper_dir}/publish-product-usb-evidence.py" \
    --create-companion "${result_log}" "${checker}"
}

publish_product_usb_staged_log() {
  local staged_log="$1" result_log="$2" checker="$3"
  local required_digest="${4:?missing required companion digest}"
  local helper_dir

  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  python3 "${helper_dir}/publish-product-usb-evidence.py" \
    "${staged_log}" "${result_log}" "${checker}" "${required_digest}"
}
