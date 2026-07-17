#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tools/mac-bundle-check-retry.sh"
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
candidate_root=""
transaction_root=""
transaction_owned=false
publication_started=false
publication_complete=false

backup_regular_node() {
  local source_path="$1"
  local backup_path="$2"
  if ! python3 "${repo_root}/tools/build-mac-dmg-prepublication.py" backup \
      "${source_path}" "${backup_path}" >/dev/null 2>&1; then
    printf 'Existing release artifact changed or is not a regular file.\n' >&2
    return 1
  fi
}

write_transaction_state() {
  local state="$1"
  if ! python3 -c '
import os
import stat
import sys

root, state = sys.argv[1:]
temporary = os.path.join(root, ".state.next")
destination = os.path.join(root, "state")
try:
    info = os.lstat(temporary)
except FileNotFoundError:
    pass
else:
    if not stat.S_ISREG(info.st_mode):
        raise RuntimeError("unsafe transaction state temporary")
    os.unlink(temporary)
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(temporary, flags, 0o600)
try:
    os.write(fd, (state + "\n").encode("ascii"))
    os.fsync(fd)
finally:
    os.close(fd)
os.replace(temporary, destination)
directory_fd = os.open(root, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
' "${transaction_root}" "${state}" >/dev/null 2>&1; then
    printf 'Release publication transaction state could not be recorded.\n' >&2
    return 1
  fi
}

write_transaction_identities() {
  if ! python3 -c '
import hashlib
import json
import os
import re
import stat
import sys

root, candidate_image, candidate_checksum, image, checksum = sys.argv[1:]

def identity(path):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError("publication node is not regular")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(fd)
        if ((before.st_dev, before.st_ino, before.st_size)
                != (after.st_dev, after.st_ino, after.st_size)):
            raise RuntimeError("publication node changed while identified")
        return {
            "dev": before.st_dev,
            "ino": before.st_ino,
            "size": before.st_size,
            "sha256": digest.hexdigest(),
        }
    finally:
        os.close(fd)

def same_identity(path, expected):
    return identity(path) == expected

candidate = {
    "output": identity(candidate_image),
    "checksum": identity(candidate_checksum),
}
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
checksum_fd = os.open(candidate_checksum, flags)
try:
    checksum_contents = os.read(checksum_fd, 4097)
finally:
    os.close(checksum_fd)
if len(checksum_contents) > 4096:
    raise RuntimeError("candidate checksum is too large")
fields = checksum_contents.decode("ascii").split()
if (not fields
        or re.fullmatch(r"[0-9a-fA-F]{64}", fields[0]) is None
        or fields[0].lower() != candidate["output"]["sha256"]):
    raise RuntimeError("candidate checksum does not match image")
previous_image = os.path.join(root, "previous.dmg")
previous_checksum = os.path.join(root, "previous.sha256")
previous_exists = os.path.lexists(previous_image)
if previous_exists != os.path.lexists(previous_checksum):
    raise RuntimeError("previous publication pair is incomplete")
if previous_exists:
    previous = {
        "output": identity(previous_image),
        "checksum": identity(previous_checksum),
    }
    if (not same_identity(image, previous["output"])
            or not same_identity(checksum, previous["checksum"])):
        raise RuntimeError("canonical pair changed while backed up")
else:
    previous = {"output": None, "checksum": None}
    if os.path.lexists(image) or os.path.lexists(checksum):
        raise RuntimeError("canonical pair appeared while preparing publication")

payload = {
    "version": 1,
    "previous": previous,
    "candidate": candidate,
    "canonical": {"before": previous, "after": candidate},
}
temporary = os.path.join(root, ".identities.next")
destination = os.path.join(root, "identities")
if os.path.lexists(temporary) or os.path.lexists(destination):
    raise RuntimeError("publication identities already exist")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(temporary, flags, 0o600)
try:
    encoded = (json.dumps(payload, sort_keys=True, separators=(",", ":"))
               + "\n").encode("ascii")
    os.write(fd, encoded)
    os.fsync(fd)
finally:
    os.close(fd)
os.replace(temporary, destination)
directory_fd = os.open(root, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
' "${transaction_root}" "${candidate_path}" \
    "${candidate_checksum_path}" "${output_path}" \
    "${output_path}.sha256" >/dev/null 2>&1; then
    printf 'Release publication identities could not be recorded.\n' >&2
    return 1
  fi
}

recorded_publication_action() {
  local action="$1"
  python3 -c '
import hashlib
import json
import os
import re
import stat
import sys

sys.path.insert(0, sys.argv[5])
from atomic_rename import EXCHANGE, EXCLUSIVE, rename_paths
root, image, checksum, action = sys.argv[1:5]
candidate_root = os.path.join(root, "candidate")
candidate_image = os.path.join(candidate_root, os.path.basename(image))
candidate_checksum = candidate_image + ".sha256"
candidate_root_info = os.lstat(candidate_root)
if (not stat.S_ISDIR(candidate_root_info.st_mode)
        or candidate_root_info.st_uid != os.geteuid()
        or stat.S_IMODE(candidate_root_info.st_mode) != 0o700):
    raise RuntimeError("candidate root is not a private owned directory")

def read_regular(path, maximum=None):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError("publication node is not regular")
        if maximum is not None and before.st_size > maximum:
            raise RuntimeError("publication metadata is too large")
        chunks = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(fd, min(1024 * 1024, remaining))
            if not chunk:
                raise RuntimeError("publication node was truncated")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(fd, 1):
            raise RuntimeError("publication node grew while read")
        after = os.fstat(fd)
        if ((before.st_dev, before.st_ino, before.st_size)
                != (after.st_dev, after.st_ino, after.st_size)):
            raise RuntimeError("publication node changed while read")
        return b"".join(chunks), before
    finally:
        os.close(fd)

def actual_identity(path):
    contents, info = read_regular(path)
    return {
        "dev": info.st_dev,
        "ino": info.st_ino,
        "size": info.st_size,
        "sha256": hashlib.sha256(contents).hexdigest(),
    }

def checked_identity(value):
    if not isinstance(value, dict) or set(value) != {"dev", "ino", "size", "sha256"}:
        raise RuntimeError("publication identity has an invalid shape")
    if (not all(isinstance(value[key], int) and value[key] >= 0
                for key in ("dev", "ino", "size"))
            or not isinstance(value["sha256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is None):
        raise RuntimeError("publication identity is invalid")
    return value

def matches(path, expected):
    try:
        return actual_identity(path) == expected
    except (FileNotFoundError, NotADirectoryError, OSError, RuntimeError):
        return False

def require_absent(path):
    if os.path.lexists(path):
        raise RuntimeError("unexpected publication node")

def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

def pair_valid(pair_image, pair_checksum):
    contents, _ = read_regular(pair_checksum, 4096)
    fields = contents.decode("ascii").split()
    if not fields or re.fullmatch(r"[0-9a-fA-F]{64}", fields[0]) is None:
        return False
    return actual_identity(pair_image)["sha256"] == fields[0].lower()

metadata, metadata_info = read_regular(os.path.join(root, "identities"), 16384)
if metadata_info.st_nlink != 1:
    raise RuntimeError("publication identities are externally linked")
payload = json.loads(metadata.decode("ascii"))
if (not isinstance(payload, dict)
        or set(payload) != {"version", "previous", "candidate", "canonical"}
        or payload["version"] != 1):
    raise RuntimeError("publication identities have an invalid schema")
previous = payload["previous"]
candidate = payload["candidate"]
canonical = payload["canonical"]
if (not isinstance(previous, dict)
        or set(previous) != {"output", "checksum"}
        or not isinstance(candidate, dict)
        or set(candidate) != {"output", "checksum"}
        or not isinstance(canonical, dict)
        or set(canonical) != {"before", "after"}
        or canonical["before"] != previous
        or canonical["after"] != candidate):
    raise RuntimeError("publication identities have invalid pairs")
candidate = {key: checked_identity(candidate[key]) for key in ("output", "checksum")}
has_previous = previous["output"] is not None
if has_previous != (previous["checksum"] is not None):
    raise RuntimeError("previous publication identity pair is incomplete")
if has_previous:
    previous = {key: checked_identity(previous[key]) for key in ("output", "checksum")}
    if (not matches(os.path.join(root, "previous.dmg"), previous["output"])
            or not matches(os.path.join(root, "previous.sha256"), previous["checksum"])):
        raise RuntimeError("previous publication backup changed")
else:
    previous = {"output": None, "checksum": None}
    require_absent(os.path.join(root, "previous.dmg"))
    require_absent(os.path.join(root, "previous.sha256"))

state_contents, _ = read_regular(os.path.join(root, "state"), 128)
state = state_contents.decode("ascii").strip()
rolling_back = state == "rolling-back"
paths = {
    "output": (candidate_image, image),
    "checksum": (candidate_checksum, checksum),
}
locations = {}
for key in ("output", "checksum"):
    candidate_path, canonical_path = paths[key]
    if matches(canonical_path, candidate[key]):
        if has_previous and os.path.lexists(candidate_path):
            if not matches(candidate_path, previous[key]):
                raise RuntimeError("displaced previous node changed")
        elif not has_previous:
            require_absent(candidate_path)
        locations[key] = "canonical"
    elif rolling_back and has_previous and matches(canonical_path, previous[key]):
        if os.path.lexists(candidate_path) and not matches(candidate_path, candidate[key]):
            raise RuntimeError("rollback candidate node changed")
        locations[key] = "restored"
    elif os.path.lexists(candidate_path):
        if not matches(candidate_path, candidate[key]):
            raise RuntimeError("candidate publication node changed")
        locations[key] = "candidate"
        if has_previous:
            if not matches(canonical_path, previous[key]):
                raise RuntimeError("canonical previous node changed")
        else:
            require_absent(canonical_path)
    elif rolling_back and not has_previous and not os.path.lexists(canonical_path):
        locations[key] = "removed"
    else:
        raise RuntimeError("recorded publication node is missing or replaced")

if action == "validate":
    raise SystemExit(0)
if action == "complete":
    if (locations != {"output": "canonical", "checksum": "canonical"}
            or not pair_valid(image, checksum)):
        raise SystemExit(1)
    raise SystemExit(0)
if action == "previous":
    raise SystemExit(0 if has_previous else 1)
if action in ("publish-output", "publish-checksum"):
    key = "output" if action == "publish-output" else "checksum"
    candidate_path, canonical_path = paths[key]
    if locations[key] != "candidate":
        raise RuntimeError("publication source is not the recorded candidate")
    rename_paths(candidate_path, canonical_path,
                 EXCHANGE if has_previous else EXCLUSIVE)
    expected_displaced = previous[key] if has_previous else None
    published = matches(canonical_path, candidate[key])
    displaced = (matches(candidate_path, expected_displaced) if has_previous
                 else not os.path.lexists(candidate_path))
    if not published or not displaced:
        rename_paths(canonical_path, candidate_path,
                     EXCHANGE if has_previous else EXCLUSIVE)
        raise RuntimeError("publication rename identity mismatch")
    sync_directory(os.path.dirname(image))
    sync_directory(candidate_root)
    sync_directory(root)
    raise SystemExit(0)
if action != "rollback":
    raise RuntimeError("unknown publication identity action")
if not rolling_back:
    raise RuntimeError("rollback was not recorded")

temporary_names = {"output": ".restore-dmg", "checksum": ".restore-sha256"}
for key in ("output", "checksum"):
    candidate_path, canonical_path = paths[key]
    if has_previous:
        if locations[key] == "restored":
            continue
        expected_current = candidate[key]
        backup = os.path.join(root, "previous.dmg" if key == "output"
                              else "previous.sha256")
        if not matches(backup, previous[key]):
            raise RuntimeError("previous backup changed before rollback")
        temporary = candidate_path
        if not matches(temporary, previous[key]):
            temporary = os.path.join(root, temporary_names[key])
            if os.path.lexists(temporary):
                if not matches(temporary, previous[key]):
                    raise RuntimeError("rollback temporary changed")
            else:
                os.link(backup, temporary, follow_symlinks=False)
        rename_paths(temporary, canonical_path, EXCHANGE)
        if (not matches(canonical_path, previous[key])
                or not matches(temporary, expected_current)):
            rename_paths(temporary, canonical_path, EXCHANGE)
            raise RuntimeError("canonical rollback identity mismatch")
    elif locations[key] == "canonical":
        temporary = os.path.join(root, temporary_names[key])
        require_absent(temporary)
        rename_paths(canonical_path, temporary, EXCLUSIVE)
        if not matches(temporary, candidate[key]) or os.path.lexists(canonical_path):
            rename_paths(temporary, canonical_path, EXCLUSIVE)
            raise RuntimeError("canonical rollback identity mismatch")

sync_directory(os.path.dirname(image))
sync_directory(candidate_root)
sync_directory(root)
' "${transaction_root}" "${output_path}" "${output_path}.sha256" \
    "${action}" "${repo_root}/tools" >/dev/null 2>&1
}

transaction_layout_safe() {
  python3 "${repo_root}/tools/build-mac-dmg-prepublication.py" \
    validate-layout "${transaction_root}" "${output_basename}" \
    >/dev/null 2>&1
}

remove_transaction_root() {
  python3 "${repo_root}/tools/build-mac-dmg-prepublication.py" \
    remove-validated "${transaction_root}" "${output_basename}" \
    >/dev/null 2>&1
}

refuse_legacy_publication_transactions() {
  if ! python3 -c '
import os
import sys
parent, image_name = sys.argv[1:]
prefix = "." + image_name + ".previous."
if any(name.startswith(prefix) for name in os.listdir(parent)):
    raise RuntimeError("legacy publication transaction exists")
' "${output_directory}" "${output_basename}" >/dev/null 2>&1; then
    printf 'A legacy release publication transaction requires manual recovery.\n' >&2
    return 1
  fi
}
recover_interrupted_publication() {
  [[ -e "${transaction_root}" || -L "${transaction_root}" ]] || return 0
  if [[ -L "${transaction_root}" || ! -d "${transaction_root}" ]] \
      || ! transaction_layout_safe; then
    printf 'Release publication transaction is unsafe; it was preserved.\n' >&2
    return 1
  fi
  local owner_pid="" recorded_owner_instance="" state=""
  local owner_status=0
  if [[ ! -e "${transaction_root}/identities" \
      && ! -L "${transaction_root}/identities" ]]; then
    if [[ -f "${transaction_root}/owner-pid" \
        && ! -L "${transaction_root}/owner-pid" \
        && -f "${transaction_root}/owner-instance" \
        && ! -L "${transaction_root}/owner-instance" ]]; then
      read -r owner_pid <"${transaction_root}/owner-pid" || true
      read -r recorded_owner_instance \
        <"${transaction_root}/owner-instance" || true
      if [[ "${owner_pid}" =~ ^[1-9][0-9]*$ ]] && \
          python3 "${repo_root}/tools/process_instance_identity.py" matches \
            "${owner_pid}" "${recorded_owner_instance}"; then
        printf 'Another release publication transaction is active.\n' >&2
        return 1
      fi
    fi
    if python3 "${repo_root}/tools/build-mac-dmg-prepublication.py" \
        recover-unidentified "${transaction_root}" "${output_path}" \
        >/dev/null 2>&1; then
      printf 'Removed an interrupted pre-publication transaction.\n'
      return 0
    fi
    printf 'Release pre-publication transaction is unsafe; it was preserved.\n' >&2
    return 1
  fi
  if [[ ! -f "${transaction_root}/owner-pid" \
      || -L "${transaction_root}/owner-pid" \
      || ! -f "${transaction_root}/owner-instance" \
      || -L "${transaction_root}/owner-instance" \
      || ! -f "${transaction_root}/state" \
      || -L "${transaction_root}/state" ]]; then
    printf 'Release publication transaction metadata is unsafe; it was preserved.\n' >&2
    return 1
  fi
  read -r owner_pid <"${transaction_root}/owner-pid" || true
  read -r recorded_owner_instance <"${transaction_root}/owner-instance" || true
  read -r state <"${transaction_root}/state" || true
  if ! [[ "${owner_pid}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Release publication transaction owner is invalid; it was preserved.\n' >&2
    return 1
  fi
  if python3 "${repo_root}/tools/process_instance_identity.py" matches \
      "${owner_pid}" "${recorded_owner_instance}"; then
    printf 'Another release publication transaction is active.\n' >&2
    return 1
  else
    owner_status=$?
  fi
  if [[ "${owner_status}" -ne 1 ]]; then
    printf 'Release publication owner identity is invalid; transaction was preserved.\n' >&2
    return 1
  fi
  case "${state}" in
    building|prepared|publishing-output|output-published|publishing-checksum|complete|rolling-back) ;;
    *)
      printf 'Release publication transaction state is invalid; it was preserved.\n' >&2
      return 1
      ;;
  esac
  if ! recorded_publication_action validate; then
    printf 'Release publication identities do not match current nodes; transaction was preserved.\n' >&2
    return 1
  fi
  if [[ "${state}" != "rolling-back" ]] \
      && recorded_publication_action complete; then
    remove_transaction_root
    printf 'Recovered a complete release artifact publication.\n'
    return 0
  fi
  if [[ "${state}" == "complete" ]]; then
    printf 'Release publication marked complete but its recorded pair is incomplete; transaction was preserved.\n' >&2
    return 1
  fi

  local has_previous=false
  if recorded_publication_action previous; then
    has_previous=true
  fi
  if [[ "${state}" != "rolling-back" ]] \
      && ! write_transaction_state rolling-back; then
    printf 'Release publication recovery could not record rollback; transaction was preserved.\n' >&2
    return 1
  fi
  if ! recorded_publication_action rollback; then
    printf 'Release publication recovery found a changed node; transaction was preserved.\n' >&2
    return 1
  fi
  remove_transaction_root
  if [[ "${has_previous}" == true ]]; then
    printf 'Restored the previous release artifact pair after an interrupted publication.\n'
  else
    printf 'Removed an incomplete release artifact publication.\n'
  fi
}

cleanup() {
  local rollback_failed=false
  if [[ "${mounted}" == true ]]; then
    hdiutil detach "${mount_path}" -quiet || true
  fi
  if [[ "${transaction_owned}" == true && -n "${transaction_root}" ]]; then
    if ! transaction_layout_safe; then
      rollback_failed=true
    elif [[ "${publication_complete}" == true ]]; then
      recorded_publication_action validate || rollback_failed=true
      recorded_publication_action complete || rollback_failed=true
    elif [[ "${publication_started}" == true ]]; then
      recorded_publication_action validate || rollback_failed=true
      if [[ "${rollback_failed}" == false ]]; then
        write_transaction_state rolling-back || rollback_failed=true
      fi
      if [[ "${rollback_failed}" == false ]]; then
        recorded_publication_action rollback || rollback_failed=true
      fi
    fi
    if [[ "${rollback_failed}" == true ]]; then
      printf 'Release artifact rollback is incomplete; previous files remain in the private transaction directory.\n' >&2
      printf '中文：发布产物回滚未完成；旧文件仍保留在私有事务目录中。\n' >&2
    elif remove_transaction_root; then
      transaction_owned=false
      transaction_root=""
      candidate_root=""
    else
      printf 'Release publication transaction cleanup is incomplete.\n' >&2
    fi
  fi
  rm -rf "${work_root}"
}
trap cleanup EXIT

verify_dmg_with_transient_retry() {
  local image_path="$1"
  local max_attempts=3
  local attempt=1
  local verify_output=""
  local verify_status=0

  while true; do
    if verify_output="$(hdiutil verify "${image_path}" 2>&1)"; then
      return 0
    else
      verify_status=$?
    fi

    if [[ "${verify_output}" != *"Resource temporarily unavailable"* \
      || "${attempt}" -ge "${max_attempts}" ]]; then
      printf '%s\n' "${verify_output}" >&2
      return "${verify_status}"
    fi

    printf 'hdiutil verify temporarily unavailable; retrying (%s/%s).\n' \
      "${attempt}" "${max_attempts}" >&2
    printf '中文：hdiutil verify 暂时不可用；正在重试（%s/%s）。\n' \
      "${attempt}" "${max_attempts}" >&2
    sleep "${attempt}"
    attempt=$((attempt + 1))
  done
}

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
output_directory="$(dirname "${output_path}")"
output_basename="$(basename "${output_path}")"
mkdir -p "${output_directory}"
if ! output_directory="$(cd "${output_directory}" && pwd -P)"; then
  printf 'Output DMG parent directory could not be resolved.\n' >&2
  exit 1
fi
output_path="${output_directory}/${output_basename}"
if [[ -L "${output_path}" \
  || (-e "${output_path}" && ! -f "${output_path}") \
  || -L "${output_path}.sha256" \
  || (-e "${output_path}.sha256" && ! -f "${output_path}.sha256") ]]; then
  printf 'Output DMG and checksum paths must be regular files or absent.\n' >&2
  exit 1
fi
transaction_root="${output_directory}/.${output_basename}.publication-transaction"
owner_instance="$(python3 "${repo_root}/tools/process_instance_identity.py" capture "$$")" || {
  printf 'Release publication owner identity could not be established.\n' >&2
  exit 1
}
refuse_legacy_publication_transactions
recover_interrupted_publication
if [[ (-e "${output_path}" && ! -e "${output_path}.sha256") \
  || (! -e "${output_path}" && -e "${output_path}.sha256") ]]; then
  printf 'Existing output DMG and checksum must form a complete pair.\n' >&2
  exit 1
fi
if ! python3 "${repo_root}/tools/build-mac-dmg-prepublication.py" initialize \
    "${transaction_root}" "${output_path}" "$$" "${owner_instance}" \
    >/dev/null 2>&1; then
  printf 'Release publication transaction could not be initialized.\n' >&2
  exit 1
fi
transaction_owned=true
candidate_root="${transaction_root}/candidate"
mkdir -m 0700 "${candidate_root}"
candidate_path="${candidate_root}/${output_basename}"
candidate_checksum_path="${candidate_path}.sha256"
ditto "${app_path}" "${staging_path}/DroidMatch.app"
ln -s /Applications "${staging_path}/Applications"

hdiutil create \
  -volname "DroidMatch ${version}" \
  -srcfolder "${staging_path}" \
  -format UDZO \
  -ov \
  "${candidate_path}" >/dev/null
verify_dmg_with_transient_retry "${candidate_path}"
hdiutil attach -readonly -nobrowse -mountpoint "${mount_path}" "${candidate_path}" >/dev/null
mounted=true

if [[ ! -L "${mount_path}/Applications" \
  || "$(readlink "${mount_path}/Applications")" != "/Applications" ]]; then
  printf 'Mounted DMG is missing the /Applications link.\n' >&2
  exit 1
fi
  droidmatch_check_app_with_retry \
  "${repo_root}/tools/check-mac-app-bundle.py" \
  "${mount_path}/DroidMatch.app" \
  "${sandboxed}"

hdiutil detach "${mount_path}" -quiet
mounted=false
(
  cd "${candidate_root}"
  shasum -a 256 "${output_basename}" > "${output_basename}.sha256"
)

# Do not expose a new image at the release path until image verification,
# read-only mount inspection, bundle validation, and checksum generation all
# succeed. The stable private sibling records ownership and phase so a later
# invocation can recover an untrappable stop around either identity-bound rename.
if [[ -e "${output_path}" ]]; then
  backup_regular_node "${output_path}" \
    "${transaction_root}/previous.dmg"
  backup_regular_node "${output_path}.sha256" \
    "${transaction_root}/previous.sha256"
fi
write_transaction_identities
if ! recorded_publication_action validate; then
  printf 'Release publication identities changed before publication.\n' >&2
  exit 1
fi
write_transaction_state prepared
write_transaction_state publishing-output
publication_started=true
if ! recorded_publication_action publish-output; then
  printf 'Release artifact publication rename failed.\n' >&2
  exit 1
fi
if ! recorded_publication_action validate; then
  printf 'Published DMG identity does not match the recorded candidate.\n' >&2
  exit 1
fi
write_transaction_state output-published
write_transaction_state publishing-checksum
if ! recorded_publication_action publish-checksum; then
  printf 'Release artifact publication rename failed.\n' >&2
  exit 1
fi
if ! recorded_publication_action validate \
    || ! recorded_publication_action complete; then
  printf 'Published DMG pair does not match the recorded candidates.\n' >&2
  exit 1
fi
write_transaction_state complete
publication_complete=true
remove_transaction_root
transaction_owned=false
transaction_root=""
candidate_root=""

printf 'Built verified local DroidMatch DMG: %s\n' "${output_path}"
printf 'SHA-256 sidecar: %s.sha256\n' "${output_path}"
printf '中文：已构建并验证本地 DroidMatch DMG：%s\n' "${output_path}"
