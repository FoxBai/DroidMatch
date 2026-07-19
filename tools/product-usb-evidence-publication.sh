#!/usr/bin/env bash

# Shared no-clobber publication boundary for already-validated evidence pairs.
# The historical filename and product-USB aliases remain for compatibility.
# 中文：已验证证据文件对共用的 no-clobber 发布边界；历史文件名与产品 USB
# 别名继续保留以兼容既有调用方。
readonly EVIDENCE_PUBLICATION_UNCERTAIN_STATUS=3
readonly PRODUCT_USB_PUBLICATION_UNCERTAIN_STATUS="${EVIDENCE_PUBLICATION_UNCERTAIN_STATUS}"

create_evidence_commit_companion() {
  local result_log="$1" checker="$2"
  local helper_dir

  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  python3 "${helper_dir}/publish-product-usb-evidence.py" \
    --create-companion "${result_log}" "${checker}"
}

publish_staged_evidence() {
  local staged_log="$1" result_log="$2" checker="$3"
  local required_digest="${4:?missing required companion digest}"
  local helper_dir

  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  python3 "${helper_dir}/publish-product-usb-evidence.py" \
    "${staged_log}" "${result_log}" "${checker}" "${required_digest}"
}

create_product_usb_commit_companion() {
  create_evidence_commit_companion "$@"
}

publish_product_usb_staged_log() {
  publish_staged_evidence "$@"
}
