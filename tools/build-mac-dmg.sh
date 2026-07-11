#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path=""
output_path=""
sandboxed=false

usage() {
  cat <<'EOF'
Usage: tools/build-mac-dmg.sh [--app <DroidMatch.app>] [--output <file.dmg>] [--sandboxed]

Builds or packages a locally ad-hoc-signed DroidMatch App into a compressed DMG,
adds an Applications link, writes a SHA-256 sidecar, mounts the image read-only,
and revalidates the mounted App. This is not Developer ID or notarization.

中文：将本地 ad-hoc 签名的 DroidMatch App 打包为压缩 DMG，加入 Applications
快捷方式与 SHA-256，并只读挂载复核。该产物不代表 Developer ID 签名或公证。
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app)
      app_path="${2:-}"
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

command -v hdiutil >/dev/null || {
  printf 'build-mac-dmg requires macOS hdiutil.\n' >&2
  exit 1
}

work_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-dmg.XXXXXX")"
mount_path="${work_root}/mounted"
mounted=false
cleanup() {
  if [[ "${mounted}" == true ]]; then
    hdiutil detach "${mount_path}" -quiet || true
  fi
  rm -rf "${work_root}"
}
trap cleanup EXIT

if [[ -z "${app_path}" ]]; then
  app_path="${work_root}/DroidMatch.app"
  build_args=(--configuration release --output "${app_path}")
  if [[ "${sandboxed}" == true ]]; then
    build_args+=(--sandboxed)
  fi
  "${repo_root}/tools/build-mac-app.sh" "${build_args[@]}"
fi

if [[ ! -d "${app_path}" || "${app_path}" != *.app ]]; then
  printf 'Expected an existing .app bundle: %s\n' "${app_path}" >&2
  exit 2
fi

version="$(plutil -extract CFBundleShortVersionString raw -o - "${app_path}/Contents/Info.plist")"
if [[ -z "${output_path}" ]]; then
  output_path="${repo_root}/mac/.build/dist/DroidMatch-${version}.dmg"
fi
if [[ "${output_path}" != *.dmg ]]; then
  printf 'Output must end in .dmg: %s\n' "${output_path}" >&2
  exit 2
fi

staging_path="${work_root}/staging"
install -d "${staging_path}" "${mount_path}"
mkdir -p "$(dirname "${output_path}")"
ditto "${app_path}" "${staging_path}/DroidMatch.app"
ln -s /Applications "${staging_path}/Applications"

rm -f "${output_path}" "${output_path}.sha256"
hdiutil create \
  -volname "DroidMatch ${version}" \
  -srcfolder "${staging_path}" \
  -format UDZO \
  -ov \
  "${output_path}" >/dev/null
hdiutil verify "${output_path}" >/dev/null
hdiutil attach -readonly -nobrowse -mountpoint "${mount_path}" "${output_path}" >/dev/null
mounted=true

if [[ ! -L "${mount_path}/Applications" \
  || "$(readlink "${mount_path}/Applications")" != "/Applications" ]]; then
  printf 'Mounted DMG is missing the /Applications link.\n' >&2
  exit 1
fi
verify_args=("${mount_path}/DroidMatch.app")
if [[ "${sandboxed}" == true ]]; then
  verify_args=(--sandboxed "${mount_path}/DroidMatch.app")
fi
python3 "${repo_root}/tools/check-mac-app-bundle.py" "${verify_args[@]}"

hdiutil detach "${mount_path}" -quiet
mounted=false
(
  cd "$(dirname "${output_path}")"
  shasum -a 256 "$(basename "${output_path}")" > "$(basename "${output_path}").sha256"
)

printf 'Built verified local DroidMatch DMG: %s\n' "${output_path}"
printf 'SHA-256 sidecar: %s.sha256\n' "${output_path}"
printf '中文：已构建并验证本地 DroidMatch DMG：%s\n' "${output_path}"
