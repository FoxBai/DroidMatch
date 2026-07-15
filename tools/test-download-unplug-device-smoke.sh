#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'device\n' >"${work}/state"
printf '0\n' >"${work}/offline-polls"

cat >"${work}/adb" <<'FAKE_ADB'
#!/usr/bin/env bash
set -euo pipefail
work="${FAKE_WORK:?}"
if [[ "$1" == devices ]]; then
  printf 'List of devices attached\n'
  [[ "$(cat "${work}/state")" == device ]] && printf 'TEST-SERIAL\tdevice\n'
  exit 0
fi
[[ "$1" == -s && "$2" == TEST-SERIAL ]] || exit 90
shift 2
case "$1" in
  get-state)
    current="$(cat "${work}/state")"
    if [[ "${current}" == offline ]]; then
      polls="$(cat "${work}/offline-polls")"
      if (( polls >= 1 )); then
        printf 'device\n' >"${work}/state"; printf 'device\n'
      else
        printf '%s\n' "$((polls + 1))" >"${work}/offline-polls"; exit 1
      fi
    else
      printf 'device\n'
    fi
    ;;
  shell) exit 0 ;;
  forward)
    if [[ "${2:-}" == --remove ]]; then
      printf '%s\n' "${3:-}" >>"${work}/removed-forwards"
    else
      count=0; [[ -f "${work}/forward-count" ]] && count="$(cat "${work}/forward-count")"
      count=$((count + 1)); printf '%s\n' "${count}" >"${work}/forward-count"
      printf '%s\n' "$((45000 + count))"
    fi
    ;;
  *) exit 91 ;;
esac
FAKE_ADB

cat >"${work}/harness" <<'FAKE_HARNESS'
#!/usr/bin/env bash
set -euo pipefail
work="${FAKE_WORK:?}"
resume=0
destination=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume) resume=1; shift ;;
    --destination) destination="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${destination}" ]] || exit 92
printf '%s\n' "${destination}" >"${work}/last-destination"
if [[ "${resume}" -eq 0 ]]; then
  printf '12345' >"${destination}.droidmatch-part"
  printf '{"checkpoint":5}\n' >"${destination}.droidmatch-transfer.json"
  printf 'offline\n' >"${work}/state"
  sleep 0.1
  exit 7
fi
dd if=/dev/zero of="${destination}" bs=16 count=1 2>/dev/null
rm -f "${destination}.droidmatch-part" "${destination}.droidmatch-transfer.json"
printf 'resume\n' >"${work}/resumed"
FAKE_HARNESS

chmod +x "${work}/adb" "${work}/harness"
destination="${work}/result.bin"
output="$({
  FAKE_WORK="${work}" DROIDMATCH_SKIP_BUILD=1 \
    bash "${repo_root}/tools/run-download-unplug-device-smoke.sh" \
      --serial TEST-SERIAL --source-path dm://app-sandbox/source.bin \
      --expected-bytes 16 --destination "${destination}" \
      --disconnect-timeout 2 --reconnect-timeout 2 --poll-interval 0.01 \
      --adb "${work}/adb" --harness "${work}/harness"
} 2>&1)"

grep -q 'UNPLUG NOW' <<<"${output}"
grep -q '现在拔线' <<<"${output}"
grep -q 'final_bytes=16' <<<"${output}"
[[ -f "${work}/resumed" && "$(wc -c <"${destination}" | tr -d '[:space:]')" == 16 ]]
[[ "$(wc -l <"${work}/removed-forwards" | tr -d '[:space:]')" == 2 ]]
[[ ! -e "${destination}.droidmatch-part" && ! -e "${destination}.droidmatch-transfer.json" ]]

# The security-pinned writer rejects a direct child of macOS's `/tmp` symlink.
# Exercise the runner-owned default and prove its artifacts are cleaned.
printf 'device\n' >"${work}/state"
printf '0\n' >"${work}/offline-polls"
rm -f "${work}/resumed" "${work}/last-destination"
{
  FAKE_WORK="${work}" DROIDMATCH_SKIP_BUILD=1 \
    bash "${repo_root}/tools/run-download-unplug-device-smoke.sh" \
      --serial TEST-SERIAL --source-path dm://app-sandbox/source.bin \
      --expected-bytes 16 \
      --disconnect-timeout 2 --reconnect-timeout 2 --poll-interval 0.01 \
      --adb "${work}/adb" --harness "${work}/harness"
} >/dev/null 2>&1
default_destination="$(cat "${work}/last-destination")"
[[ "${default_destination}" == /private/tmp/droidmatch-download-unplug-*.bin ]]
[[ ! -e "${default_destination}" ]]
[[ ! -e "${default_destination}.droidmatch-part" ]]
[[ ! -e "${default_destination}.droidmatch-transfer.json" ]]
printf 'download-unplug device smoke offline test passed.\n'
