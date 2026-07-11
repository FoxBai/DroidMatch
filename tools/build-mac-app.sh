#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="debug"
output_path="${repo_root}/mac/.build/app/DroidMatch.app"
sandboxed=false

usage() {
  cat <<'EOF'
Usage: tools/build-mac-app.sh [--configuration debug|release] [--output <DroidMatch.app>] [--sandboxed]

Builds the SwiftUI product with SwiftPM, assembles a local .app bundle, and
applies an ad-hoc signature. Distribution signing and notarization still require
a configured release identity; tools/build-mac-dmg.sh packages the verified
local App without making a distribution-signing claim.
Pass --sandboxed to require and embed adb, then sign with the checked-in local
App Sandbox entitlements for product-boundary verification.

中文：使用 SwiftPM 构建 SwiftUI 产品，组装本地 .app 并执行 ad-hoc 签名。
分发签名和公证仍需要已配置的发布身份；tools/build-mac-dmg.sh 可打包已验证的
本地 App，但不代表已完成分发签名。
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --configuration)
      configuration="${2:-}"
      shift 2
      ;;
    --output)
      output_path="${2:-}"
      shift 2
      ;;
    --sandboxed)
      sandboxed=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${configuration}" != "debug" && "${configuration}" != "release" ]]; then
  printf 'Unsupported configuration: %s\n' "${configuration}" >&2
  exit 2
fi
if [[ -z "${output_path}" || "${output_path}" != *.app ]]; then
  printf 'Output must be a non-empty .app path.\n' >&2
  exit 2
fi

swift_build_args=(
  build
  --package-path "${repo_root}/mac"
  --configuration "${configuration}"
)
if [[ -n "${DROIDMATCH_SWIFT_SCRATCH_PATH:-}" ]]; then
  swift_build_args+=(--scratch-path "${DROIDMATCH_SWIFT_SCRATCH_PATH}")
fi

swift "${swift_build_args[@]}" --product DroidMatch

bin_path="$(swift "${swift_build_args[@]}" --show-bin-path)"
executable_path="${bin_path}/DroidMatch"
resource_bundle_path="${bin_path}/DroidMatchMac_DroidMatchApp.bundle"
protobuf_resource_bundle_path="${bin_path}/SwiftProtobuf_SwiftProtobuf.bundle"
icon_work_path="${repo_root}/mac/.build/app-icon"
iconset_path="${icon_work_path}/DroidMatch.iconset"
master_icon_path="${icon_work_path}/DroidMatch-1024.png"

if [[ ! -x "${executable_path}" \
    || ! -d "${resource_bundle_path}" \
    || ! -f "${protobuf_resource_bundle_path}/PrivacyInfo.xcprivacy" ]]; then
  printf 'SwiftPM did not produce the expected executable, app resources, or dependency privacy manifest.\n' >&2
  exit 1
fi

rm -rf "${output_path}"
install -d "${output_path}/Contents/MacOS" "${output_path}/Contents/Resources"
install -m 0755 "${executable_path}" "${output_path}/Contents/MacOS/DroidMatch"
install -m 0644 "${repo_root}/mac/App/Info.plist" "${output_path}/Contents/Info.plist"
install -m 0644 "${repo_root}/mac/App/PrivacyInfo.xcprivacy" \
  "${output_path}/Contents/Resources/PrivacyInfo.xcprivacy"
ditto \
  "${resource_bundle_path}" \
  "${output_path}/Contents/Resources/DroidMatchMac_DroidMatchApp.bundle"
ditto \
  "${protobuf_resource_bundle_path}" \
  "${output_path}/Contents/Resources/SwiftProtobuf_SwiftProtobuf.bundle"
ditto \
  "${repo_root}/third_party/mac" \
  "${output_path}/Contents/Resources/Legal"

if [[ "${sandboxed}" == true ]]; then
  adb_source="${DROIDMATCH_ADB:-}"
  if [[ -z "${adb_source}" && -n "${ANDROID_HOME:-}" ]]; then
    adb_source="${ANDROID_HOME}/platform-tools/adb"
  fi
  if [[ -z "${adb_source}" && -n "${ANDROID_SDK_ROOT:-}" ]]; then
    adb_source="${ANDROID_SDK_ROOT}/platform-tools/adb"
  fi
  if [[ -z "${adb_source}" ]]; then
    adb_source="${HOME}/Library/Android/sdk/platform-tools/adb"
  fi
  if [[ ! -x "${adb_source}" ]]; then
    printf 'Sandboxed build requires an executable adb via DROIDMATCH_ADB or Android SDK platform-tools.\n' >&2
    exit 1
  fi
  platform_tools_dir="$(cd "$(dirname "${adb_source}")" && pwd)"
  install -d "${output_path}/Contents/Resources/platform-tools"
  install -m 0755 "${adb_source}" "${output_path}/Contents/Resources/platform-tools/adb"
  if [[ ! -f "${platform_tools_dir}/NOTICE.txt" ]]; then
    printf 'Sandboxed build requires platform-tools NOTICE.txt beside adb.\n' >&2
    exit 1
  fi
  install -m 0644 "${platform_tools_dir}/NOTICE.txt" \
    "${output_path}/Contents/Resources/platform-tools/NOTICE.txt"
fi

rm -rf "${icon_work_path}"
install -d "${iconset_path}"
swift "${repo_root}/tools/render-mac-icon.swift" "${master_icon_path}"
for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" "${master_icon_path}" \
    --out "${iconset_path}/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "${double_size}" "${double_size}" "${master_icon_path}" \
    --out "${iconset_path}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${iconset_path}" \
  -o "${output_path}/Contents/Resources/DroidMatch.icns"

plutil -lint "${output_path}/Contents/Info.plist" >/dev/null
if [[ "${sandboxed}" == true ]]; then
  codesign --force --sign - "${output_path}/Contents/Resources/platform-tools/adb"
  codesign --force --deep --sign - \
    --entitlements "${repo_root}/mac/App/DroidMatch.entitlements" \
    "${output_path}"
else
  codesign --force --deep --sign - "${output_path}"
fi
codesign --verify --deep --strict "${output_path}"

if [[ "${sandboxed}" == true ]]; then
  python3 "${repo_root}/tools/check-mac-app-bundle.py" --sandboxed "${output_path}"
else
  python3 "${repo_root}/tools/check-mac-app-bundle.py" "${output_path}"
fi

printf 'Built local DroidMatch app: %s\n' "${output_path}"
printf '中文：已构建本地 DroidMatch App：%s\n' "${output_path}"
