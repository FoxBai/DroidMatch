#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  printf 'Usage: build-mac-icon.sh <repo-root> <work-root> <output.icns>\n' >&2
  exit 2
fi

repo_root="$1"
work_root="$2"
output_path="$3"
iconset_path="${work_root}/DroidMatch.iconset"
verification_path="${work_root}/Verified.iconset"
master_icon_path="${work_root}/DroidMatch-1024.png"

[[ -d "${repo_root}" && -d "$(dirname "${output_path}")" \
    && "${output_path}" == *.icns ]] || {
  printf 'Mac icon paths are invalid.\n' >&2
  exit 2
}
mkdir -p "${iconset_path}"

swift "${repo_root}/tools/render-mac-icon.swift" "${master_icon_path}"
for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" "${master_icon_path}" \
    --out "${iconset_path}/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "${double_size}" "${double_size}" "${master_icon_path}" \
    --out "${iconset_path}/icon_${size}x${size}@2x.png" >/dev/null
done

python3 "${repo_root}/tools/package-mac-icon.py" \
  "${iconset_path}" "${output_path}"
# macOS 26.5 can reject a valid iconset during encoding while still decoding
# the equivalent modern ICNS container. Require the platform decoder to accept
# the packaged result before the candidate App is signed or published.
iconutil -c iconset "${output_path}" -o "${verification_path}"
