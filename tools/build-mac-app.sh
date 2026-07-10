#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="debug"
output_path="${repo_root}/mac/.build/app/DroidMatch.app"

usage() {
  cat <<'EOF'
Usage: tools/build-mac-app.sh [--configuration debug|release] [--output <DroidMatch.app>]

Builds the SwiftUI product with SwiftPM, assembles a local .app bundle, and
applies an ad-hoc signature. Distribution signing, notarization, and DMG
packaging still require a configured full Xcode environment.

中文：使用 SwiftPM 构建 SwiftUI 产品，组装本地 .app 并执行 ad-hoc 签名。
分发签名、公证与 DMG 仍需要已配置的完整 Xcode 环境。
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

swift build \
  --package-path "${repo_root}/mac" \
  --configuration "${configuration}" \
  --product DroidMatch

bin_path="$(swift build \
  --package-path "${repo_root}/mac" \
  --configuration "${configuration}" \
  --show-bin-path)"
executable_path="${bin_path}/DroidMatch"
resource_bundle_path="${bin_path}/DroidMatchMac_DroidMatchApp.bundle"
icon_work_path="${repo_root}/mac/.build/app-icon"
iconset_path="${icon_work_path}/DroidMatch.iconset"
master_icon_path="${icon_work_path}/DroidMatch-1024.png"

if [[ ! -x "${executable_path}" || ! -d "${resource_bundle_path}" ]]; then
  printf 'SwiftPM did not produce the expected app executable or resource bundle.\n' >&2
  exit 1
fi

rm -rf "${output_path}"
install -d "${output_path}/Contents/MacOS" "${output_path}/Contents/Resources"
install -m 0755 "${executable_path}" "${output_path}/Contents/MacOS/DroidMatch"
install -m 0644 "${repo_root}/mac/App/Info.plist" "${output_path}/Contents/Info.plist"
ditto \
  "${resource_bundle_path}" \
  "${output_path}/Contents/Resources/DroidMatchMac_DroidMatchApp.bundle"

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
codesign --force --deep --sign - "${output_path}"
codesign --verify --deep --strict "${output_path}"

printf 'Built local DroidMatch app: %s\n' "${output_path}"
printf '中文：已构建本地 DroidMatch App：%s\n' "${output_path}"
