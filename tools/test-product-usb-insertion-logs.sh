#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/tools/check-product-usb-insertion-logs.sh"
source "${repo_root}/tools/product-usb-evidence-publication.sh"
cd "${repo_root}"
work="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-product-usb-log-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
real_grep="$(command -v grep)"
real_ln="$(command -v ln)"
mkdir "${work}/bin"
cat >"${work}/bin/grep" <<'FAKE_GREP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_GREP_CONTROL_FAILURE:-0}" == "1" \
    && "$*" == *'[[:cntrl:]]'* ]]; then
  exit 74
fi
exec "${REAL_GREP:?}" "$@"
FAKE_GREP
chmod +x "${work}/bin/grep"

valid="${work}/valid.md"
cat >"${valid}" <<'EOF'
# M1 Product USB Insertion Evidence

status: passed
evidence profile: m1-product-usb-insertion-v1
profile result: passed
date: 2026-07-13 00:00:00Z
device slot: C
device label: MEIZU M20
bundle id: app.droidmatch.mac
profile source revision: 1111111111111111111111111111111111111111
profile expected main revision: 1111111111111111111111111111111111111111
profile origin main revision: 1111111111111111111111111111111111111111
bundle source revision: 1111111111111111111111111111111111111111
bundle source dirty: false
bundle build configuration: release
bundle sandboxed: false
bundle executable sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
running code requirement verified: true
running app count: 1
running bundle matched requested app: true
bundle verification: passed
repository clean before run: true
repository clean after run: true
preflight matching elements: 0
pre-signal matching elements: 0
operator arm acknowledged: true
operator physical insertion attested: true
measurement clock: CLOCK_MONOTONIC
measurement boundary: monotonic-before-insert-now
countdown seconds: 3
poll interval ms: 100
threshold ms: 5000
elapsed ms: 2431
completion matching elements: 1
product visible: true
accessibility identifier: app.droidmatch.discovery-device-card
probe override: false
EOF

bash "${checker}" --log "${valid}" >/dev/null

expect_checker_rejection() {
  local mode="$1" path="$2" label="$3"
  if bash "${checker}" "${mode}" "${path}" >/dev/null 2>&1; then
    printf 'product USB evidence checker accepted non-regular input: %s\n' \
      "${label}" >&2
    exit 1
  fi
}

# Both entry points reject filesystem indirection before reading content. A FIFO
# must be rejected by its type check rather than opened and allowed to block.
single_symlink="${work}/single-symlink.md"
"${real_ln}" -s "${valid}" "${single_symlink}"
expect_checker_rejection --log "${single_symlink}" 'single-log symlink'

single_directory="${work}/single-directory.md"
mkdir "${single_directory}"
expect_checker_rejection --log "${single_directory}" 'single-log directory'

single_fifo="${work}/single-fifo.md"
mkfifo "${single_fifo}"
expect_checker_rejection --log "${single_fifo}" 'single-log FIFO'

directory_symlink_entries="${work}/directory-symlink-entries"
mkdir "${directory_symlink_entries}"
cp "${valid}" "${directory_symlink_entries}/valid.md"
cp "${valid}" "${directory_symlink_entries}/valid.md.commit"
"${real_ln}" -s "${valid}" "${directory_symlink_entries}/linked.md"
expect_checker_rejection \
  --directory "${directory_symlink_entries}" 'directory-mode symlink entry'

directory_directory_entries="${work}/directory-directory-entries"
mkdir "${directory_directory_entries}"
cp "${valid}" "${directory_directory_entries}/valid.md"
cp "${valid}" "${directory_directory_entries}/valid.md.commit"
mkdir "${directory_directory_entries}/nested.md"
expect_checker_rejection \
  --directory "${directory_directory_entries}" 'directory-mode directory entry'

directory_fifo_entries="${work}/directory-fifo-entries"
mkdir "${directory_fifo_entries}"
cp "${valid}" "${directory_fifo_entries}/valid.md"
cp "${valid}" "${directory_fifo_entries}/valid.md.commit"
mkfifo "${directory_fifo_entries}/pipe.md"
expect_checker_rejection \
  --directory "${directory_fifo_entries}" 'directory-mode FIFO entry'

directory_target="${work}/real-directory"
directory_link="${work}/linked-directory"
mkdir "${directory_target}"
"${real_ln}" -s "${directory_target}" "${directory_link}"
expect_checker_rejection --directory "${directory_link}" 'directory path symlink'

directory_valid="${work}/directory-valid"
mkdir "${directory_valid}"
printf '%s\n' '# Product USB evidence fixtures' >"${directory_valid}/README.md"
cp "${valid}" "${directory_valid}/visible-valid.md"
cp "${valid}" "${directory_valid}/visible-valid.md.commit"
bash "${checker}" --directory "${directory_valid}" >/dev/null

directory_empty="${work}/directory-empty"
mkdir "${directory_empty}"
printf '%s\n' '# Product USB evidence fixtures' >"${directory_empty}/README.md"
bash "${checker}" --directory "${directory_empty}" >/dev/null

readme_companion_directory="${work}/directory-readme-companion"
mkdir "${readme_companion_directory}"
printf '%s\n' '# Product USB evidence fixtures' \
  >"${readme_companion_directory}/README.md"
cp "${readme_companion_directory}/README.md" \
  "${readme_companion_directory}/README.md.commit"
expect_checker_rejection \
  --directory "${readme_companion_directory}" 'README commit companion'

directory_truly_empty="${work}/directory-truly-empty"
mkdir "${directory_truly_empty}"
bash "${checker}" --directory "${directory_truly_empty}" >/dev/null

orphan_evidence_directory="${work}/directory-orphan-evidence"
mkdir "${orphan_evidence_directory}"
cp "${valid}" "${orphan_evidence_directory}/orphan.md"
expect_checker_rejection \
  --directory "${orphan_evidence_directory}" 'evidence without commit companion'

orphan_commit_directory="${work}/directory-orphan-commit"
mkdir "${orphan_commit_directory}"
cp "${valid}" "${orphan_commit_directory}/orphan.md.commit"
expect_checker_rejection \
  --directory "${orphan_commit_directory}" 'commit companion without evidence'

mismatched_commit_directory="${work}/directory-mismatched-commit"
mkdir "${mismatched_commit_directory}"
cp "${valid}" "${mismatched_commit_directory}/mismatch.md"
sed 's/device label: MEIZU M20/device label: SHARP 704SH/' \
  "${valid}" >"${mismatched_commit_directory}/mismatch.md.commit"
expect_checker_rejection \
  --directory "${mismatched_commit_directory}" 'mismatched commit companion'

commit_symlink_directory="${work}/directory-commit-symlink"
mkdir "${commit_symlink_directory}"
cp "${valid}" "${commit_symlink_directory}/linked.md"
"${real_ln}" -s "${valid}" "${commit_symlink_directory}/linked.md.commit"
expect_checker_rejection \
  --directory "${commit_symlink_directory}" 'symlink commit companion'

hidden_valid_directory="${work}/directory-hidden-valid"
mkdir "${hidden_valid_directory}"
cp "${valid}" "${hidden_valid_directory}/.hidden-valid.md"
expect_checker_rejection \
  --directory "${hidden_valid_directory}" 'hidden valid evidence'

metadata_directory="${work}/directory-metadata"
mkdir "${metadata_directory}"
printf '%s\n' 'metadata' >"${metadata_directory}/.DS_Store"
expect_checker_rejection --directory "${metadata_directory}" 'hidden metadata'

staging_directory="${work}/directory-staging-residue"
mkdir "${staging_directory}"
cp "${valid}" "${staging_directory}/.product-usb-insertion.ABCDEF"
expect_checker_rejection --directory "${staging_directory}" 'staging residue'

unexpected_file_directory="${work}/directory-unexpected-file"
mkdir "${unexpected_file_directory}"
cp "${valid}" "${unexpected_file_directory}/unexpected.txt"
expect_checker_rejection \
  --directory "${unexpected_file_directory}" 'unexpected non-Markdown file'

unexpected_directory="${work}/directory-unexpected-directory"
mkdir "${unexpected_directory}" "${unexpected_directory}/nested"
expect_checker_rejection \
  --directory "${unexpected_directory}" 'unexpected nested directory'

unexpected_fifo_directory="${work}/directory-unexpected-fifo"
mkdir "${unexpected_fifo_directory}"
mkfifo "${unexpected_fifo_directory}/pipe"
expect_checker_rejection \
  --directory "${unexpected_fifo_directory}" 'unexpected FIFO'

unexpected_symlink_directory="${work}/directory-unexpected-symlink"
mkdir "${unexpected_symlink_directory}"
"${real_ln}" -s "${valid}" "${unexpected_symlink_directory}/linked"
expect_checker_rejection \
  --directory "${unexpected_symlink_directory}" 'unexpected symlink'

readme_symlink_directory="${work}/directory-readme-symlink"
mkdir "${readme_symlink_directory}"
"${real_ln}" -s "${valid}" "${readme_symlink_directory}/README.md"
expect_checker_rejection \
  --directory "${readme_symlink_directory}" 'README symlink'

cat >"${work}/publication-checker" <<'PUBLICATION_CHECKER'
#!/usr/bin/env bash
set -euo pipefail

path="${2:?missing checked path}"
bash "${REAL_CHECKER:?}" "$@" || exit $?
count=0
[[ ! -f "${PUBLICATION_STATE:?}" ]] || read -r count <"${PUBLICATION_STATE}"
count=$((count + 1))
printf '%s\n' "${count}" >"${PUBLICATION_STATE}"
if [[ "${count}" -eq 1 ]]; then
  case "${PUBLICATION_MODE:-pass}" in
    pass|result-validator-failure) ;;
    target-regular-race)
      printf '%s\n' 'concurrent-writer-sentinel' >"${RESULT_PATH:?}"
      ;;
    target-directory-race)
      mkdir "${RESULT_PATH:?}"
      ;;
    target-symlink-race)
      mkdir "${RESULT_PATH:?}.directory"
      ln -s "${RESULT_PATH}.directory" "${RESULT_PATH}"
      ;;
    source-regular-race)
      rm -f "${STAGED_PATH}"
      cp "${ALTERNATE_PATH:?}" "${STAGED_PATH}"
      ;;
    source-symlink-race)
      rm -f "${STAGED_PATH}"
      ln -s "${ALTERNATE_PATH:?}" "${STAGED_PATH}"
      ;;
    *) exit 82 ;;
  esac
elif [[ "${count}" -eq 2 ]]; then
  case "${PUBLICATION_MODE:-pass}" in
    result-validator-failure) exit 83 ;;
  esac
fi
PUBLICATION_CHECKER
chmod +x "${work}/publication-checker"

run_publication() (
  state="${work}/publication-checker-count"
  rm -f "${state}"
  export REAL_CHECKER="${checker}"
  export PUBLICATION_MODE="$1"
  export PUBLICATION_STATE="${state}"
  export STAGED_PATH="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
  export RESULT_PATH="$(cd "$(dirname "$3")" && pwd -P)/$(basename "$3")"
  alternate="${4:-${valid}}"
  export ALTERNATE_PATH="$(cd "$(dirname "${alternate}")" && pwd -P)/$(basename "${alternate}")"
  required_digest="$(shasum -a 256 "$2" | awk '{print $1}')"
  publish_product_usb_staged_log \
    "$2" "$3" "${work}/publication-checker" "${required_digest}"
)

expect_publication_failure() {
  local label="$1" mode="$2" staged="$3" result="$4" alternate="${5:-${valid}}"
  local expected_status="${6:-}" output status
  set +e
  output="$(run_publication "${mode}" "${staged}" "${result}" "${alternate}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    printf 'product USB publisher accepted failure case: %s\n' "${label}" >&2
    exit 1
  fi
  if [[ -n "${expected_status}" && "${status}" -ne "${expected_status}" ]]; then
    printf 'product USB publisher returned status %s instead of %s: %s\n' \
      "${status}" "${expected_status}" "${label}" >&2
    exit 1
  fi
  if [[ "${output}" == *'Product USB insertion evidence written'* \
      || "${output}" == *'product_usb_insertion_elapsed_ms='* ]]; then
    printf 'product USB publisher reported success for failure case: %s\n' \
      "${label}" >&2
    exit 1
  fi
}

# Successful publication retains a byte-identical regular result/commit pair
# after the strict single-log validator has accepted the record.
success_directory="${work}/publication-success"
mkdir "${success_directory}"
success_result="${success_directory}/result.md"
success_staged="${success_result}.commit"
success_digest="$(
  create_product_usb_commit_companion \
    "${success_result}" "${checker}" <"${valid}"
)"
[[ "${success_digest}" =~ ^[0-9a-f]{64}$ ]]
[[ -f "${success_staged}" && ! -L "${success_staged}" ]]
[[ ! -e "${success_result}" && ! -L "${success_result}" ]]
publish_product_usb_staged_log \
  "${success_staged}" "${success_result}" "${checker}" "${success_digest}"
[[ -f "${success_result}" && ! -L "${success_result}" ]]
[[ -f "${success_staged}" && ! -L "${success_staged}" ]]
cmp -s "${success_result}" "${success_staged}"
[[ ! "${success_result}" -ef "${success_staged}" ]]
bash "${checker}" --log "${success_result}" >/dev/null
bash "${checker}" --directory "${success_directory}" >/dev/null

# The generic aliases used by non-USB evidence producers must execute the same
# validated no-clobber transaction, while the historical names stay compatible.
generic_directory="${work}/publication-generic-alias"
mkdir "${generic_directory}"
generic_result="${generic_directory}/result.md"
generic_staged="${generic_result}.commit"
generic_digest="$(
  create_evidence_commit_companion \
    "${generic_result}" "${checker}" <"${valid}"
)"
publish_staged_evidence \
  "${generic_staged}" "${generic_result}" "${checker}" "${generic_digest}"
cmp -s "${generic_result}" "${generic_staged}"
bash "${checker}" --directory "${generic_directory}" >/dev/null
[[ "${EVIDENCE_PUBLICATION_UNCERTAIN_STATUS}" \
    == "${PRODUCT_USB_PUBLICATION_UNCERTAIN_STATUS}" ]]

# Companion creation itself must refuse a replaced symlink or FIFO immediately;
# it must never follow /dev/null or block while opening a named pipe.
# 中文：伴随文件创建必须立即拒绝被替换的 symlink/FIFO，不得跟随
# /dev/null，也不得在打开命名管道时阻塞。
unsafe_creation_directory="${work}/unsafe-companion-creation"
mkdir "${unsafe_creation_directory}"
symlink_creation_result="${unsafe_creation_directory}/symlink.md"
fifo_creation_result="${unsafe_creation_directory}/fifo.md"
"${real_ln}" -s /dev/null "${symlink_creation_result}.commit"
mkfifo "${fifo_creation_result}.commit"
python3 - \
  "${repo_root}/tools/publish-product-usb-evidence.py" \
  "${checker}" "${valid}" \
  "${symlink_creation_result}" "${fifo_creation_result}" <<'PYTHON_UNSAFE_CREATE'
import subprocess
import sys

helper, checker, valid, *results = sys.argv[1:]
with open(valid, "rb") as source:
    evidence = source.read()
for result in results:
    try:
        completed = subprocess.run(
            [sys.executable, helper, "--create-companion", result, checker],
            input=evidence,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=2,
        )
    except subprocess.TimeoutExpired as error:
        raise SystemExit(90) from error
    if completed.returncode == 0:
        raise SystemExit(91)
PYTHON_UNSAFE_CREATE
[[ -L "${symlink_creation_result}.commit" ]]
[[ -p "${fifo_creation_result}.commit" ]]
[[ ! -e "${symlink_creation_result}" && ! -L "${symlink_creation_result}" ]]
[[ ! -e "${fifo_creation_result}" && ! -L "${fifo_creation_result}" ]]

# Privacy/schema rejection happens in a private unlinked file, before either
# fixture pathname exists. Rejected sensitive input must leave no repository
# residue that a broad git add could capture.
# 中文：隐私/结构拒绝必须在私有无链接文件中完成，且早于两个 fixture 路径创建；
# 被拒绝的敏感输入不得留下可被宽泛 git add 收集的仓库残留。
sensitive_creation_input="${work}/sensitive-creation-input.md"
sed 's/device label: MEIZU M20/device label: PASSWORD=PRIVATE-VALUE/' \
  "${valid}" >"${sensitive_creation_input}"
sensitive_creation_result="${work}/sensitive-creation/result.md"
mkdir "$(dirname "${sensitive_creation_result}")"
if create_product_usb_commit_companion \
    "${sensitive_creation_result}" "${checker}" \
    <"${sensitive_creation_input}" >/dev/null 2>&1; then
  printf '%s\n' 'companion creator accepted privacy-rejected evidence.' >&2
  exit 1
fi
[[ ! -e "${sensitive_creation_result}" && ! -L "${sensitive_creation_result}" ]]
[[ ! -e "${sensitive_creation_result}.commit" \
    && ! -L "${sensitive_creation_result}.commit" ]]

# The digest returned by safe creation binds the handoff into publication. A
# different but schema-valid companion substituted between the two helpers must
# be rejected before a result is created.
# 中文：安全创建返回的 digest 绑定后续发布；两个 helper 之间即使换入另一份
# 结构合法伴随文件，也必须在创建 result 前被拒绝。
handoff_directory="${work}/publication-handoff-replacement"
mkdir "${handoff_directory}"
handoff_result="${handoff_directory}/result.md"
handoff_staged="${handoff_result}.commit"
handoff_digest="$(
  create_product_usb_commit_companion \
    "${handoff_result}" "${checker}" <"${valid}"
)"
handoff_alternate="${work}/handoff-alternate.md"
sed 's/device label: MEIZU M20/device label: SHARP 704SH/' \
  "${valid}" >"${handoff_alternate}"
rm -f "${handoff_staged}"
cp "${handoff_alternate}" "${handoff_staged}"
if publish_product_usb_staged_log \
    "${handoff_staged}" "${handoff_result}" "${checker}" "${handoff_digest}"; then
  printf '%s\n' 'publisher accepted a digest-mismatched handoff replacement.' >&2
  exit 1
fi
[[ ! -e "${handoff_result}" && ! -L "${handoff_result}" ]]
cmp -s "${handoff_staged}" "${handoff_alternate}"

# Publisher path reopens are nonblocking and then type-checked. Replacing the
# companion with a FIFO between creation and publication must fail promptly.
# 中文：发布器按路径重开时必须非阻塞并随即检查类型；在创建与发布之间把
# 伴随文件换成 FIFO 必须迅速失败。
publisher_fifo_directory="${work}/publisher-fifo"
mkdir "${publisher_fifo_directory}"
publisher_fifo_result="${publisher_fifo_directory}/result.md"
mkfifo "${publisher_fifo_result}.commit"
python3 - \
  "${repo_root}/tools/publish-product-usb-evidence.py" \
  "${publisher_fifo_result}.commit" "${publisher_fifo_result}" \
  "${checker}" <<'PYTHON_PUBLISHER_FIFO'
import subprocess
import sys

helper, staged, result, checker = sys.argv[1:]
try:
    completed = subprocess.run(
        [sys.executable, helper, staged, result, checker, "0" * 64],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=2,
    )
except subprocess.TimeoutExpired as error:
    raise SystemExit(90) from error
if completed.returncode == 0:
    raise SystemExit(91)
PYTHON_PUBLISHER_FIFO
[[ -p "${publisher_fifo_result}.commit" ]]
[[ ! -e "${publisher_fifo_result}" && ! -L "${publisher_fifo_result}" ]]

existing_result="${work}/publication-existing.md"
existing_staged="${existing_result}.commit"
cp "${valid}" "${existing_staged}"
printf '%s\n' 'existing-writer-sentinel' >"${existing_result}"
expect_publication_failure \
  existing-target pass "${existing_staged}" "${existing_result}"
grep -Fqx 'existing-writer-sentinel' "${existing_result}"

dangling_result="${work}/publication-dangling.md"
dangling_staged="${dangling_result}.commit"
cp "${valid}" "${dangling_staged}"
"${real_ln}" -s "${work}/missing-target" "${dangling_result}"
expect_publication_failure \
  dangling-symlink pass "${dangling_staged}" "${dangling_result}"
[[ -L "${dangling_result}" && ! -e "${dangling_result}" ]]

directory_result="${work}/publication-directory-symlink.md"
directory_staged="${directory_result}.commit"
directory_result_target="${work}/publication-directory-symlink-target"
cp "${valid}" "${directory_staged}"
mkdir "${directory_result_target}"
"${real_ln}" -s "${directory_result_target}" "${directory_result}"
expect_publication_failure \
  directory-symlink pass "${directory_staged}" "${directory_result}"
[[ -L "${directory_result}" ]]
[[ -z "$(find "${directory_result_target}" -mindepth 1 -print -quit)" ]]

staged_symlink_result="${work}/publication-staged-symlink.md"
staged_symlink="${staged_symlink_result}.commit"
"${real_ln}" -s "${valid}" "${staged_symlink}"
expect_publication_failure \
  staged-symlink pass "${staged_symlink}" "${staged_symlink_result}"
[[ -L "${staged_symlink}" && ! -e "${staged_symlink_result}" ]]

regular_race_result="${work}/publication-regular-race.md"
regular_race_staged="${regular_race_result}.commit"
cp "${valid}" "${regular_race_staged}"
expect_publication_failure \
  regular-file-race target-regular-race \
  "${regular_race_staged}" "${regular_race_result}"
grep -Fqx 'concurrent-writer-sentinel' "${regular_race_result}"

directory_race_result="${work}/publication-directory-race.md"
directory_race_staged="${directory_race_result}.commit"
cp "${valid}" "${directory_race_staged}"
expect_publication_failure \
  real-directory-race target-directory-race \
  "${directory_race_staged}" "${directory_race_result}"
[[ -d "${directory_race_result}" && ! -L "${directory_race_result}" ]]
[[ -z "$(find "${directory_race_result}" -mindepth 1 -print -quit)" ]]

symlink_race_result="${work}/publication-symlink-race.md"
symlink_race_staged="${symlink_race_result}.commit"
cp "${valid}" "${symlink_race_staged}"
expect_publication_failure \
  target-symlink-race target-symlink-race \
  "${symlink_race_staged}" "${symlink_race_result}"
[[ -L "${symlink_race_result}" ]]
[[ -z "$(find "${symlink_race_result}.directory" -mindepth 1 -print -quit)" ]]

source_regular_result="${work}/publication-source-regular-race.md"
source_regular_staged="${source_regular_result}.commit"
source_regular_alternate="${work}/source-regular-alternate.md"
cp "${valid}" "${source_regular_staged}"
cp "${valid}" "${source_regular_alternate}"
expect_publication_failure \
  source-regular-race source-regular-race \
  "${source_regular_staged}" "${source_regular_result}" \
  "${source_regular_alternate}"
[[ -f "${source_regular_staged}" && ! -L "${source_regular_staged}" ]]
[[ ! -e "${source_regular_result}" && ! -L "${source_regular_result}" ]]

source_symlink_result="${work}/publication-source-symlink-race.md"
source_symlink_staged="${source_symlink_result}.commit"
cp "${valid}" "${source_symlink_staged}"
expect_publication_failure \
  source-symlink-race source-symlink-race \
  "${source_symlink_staged}" "${source_symlink_result}" "${valid}"
[[ -L "${source_symlink_staged}" ]]
[[ ! -e "${source_symlink_result}" && ! -L "${source_symlink_result}" ]]

invalid_result="${work}/publication-invalid.md"
invalid_staged="${invalid_result}.commit"
sed 's/^status: passed$/status: failed/' "${valid}" >"${invalid_staged}"
expect_publication_failure \
  validator-failure pass "${invalid_staged}" "${invalid_result}"
[[ ! -e "${invalid_result}" && ! -L "${invalid_result}" ]]

result_validator_directory="${work}/publication-result-validator"
mkdir "${result_validator_directory}"
result_validator_result="${result_validator_directory}/result.md"
result_validator_staged="${result_validator_result}.commit"
cp "${valid}" "${result_validator_staged}"
expect_publication_failure \
  result-validator-failure result-validator-failure \
  "${result_validator_staged}" "${result_validator_result}" "${valid}" \
  "${PRODUCT_USB_PUBLICATION_UNCERTAIN_STATUS}"
[[ -f "${result_validator_staged}" && ! -L "${result_validator_staged}" ]]
[[ -f "${result_validator_result}" && ! -L "${result_validator_result}" ]]
bash "${checker}" --directory "${result_validator_directory}" >/dev/null

# Replace the companion in the exact result-creation window. The result must
# still be copied from the pinned validated descriptor, leaving a mismatch that
# the directory gate rejects; production never removes either pathname.
# 中文：在精确的 result 创建窗口替换伴随文件；result 仍必须来自已固定验证的
# 描述符，从而留下会被全目录门禁拒绝的 mismatch。
creation_window_directory="${work}/publication-creation-window"
mkdir "${creation_window_directory}"
creation_window_result="${creation_window_directory}/result.md"
creation_window_staged="${creation_window_result}.commit"
creation_window_alternate="${work}/creation-window-alternate.md"
cp "${valid}" "${creation_window_staged}"
sed 's/device label: MEIZU M20/device label: SHARP 704SH/' \
  "${valid}" >"${creation_window_alternate}"
python3 - \
  "${repo_root}/tools/publish-product-usb-evidence.py" \
  "${creation_window_staged}" "${creation_window_result}" "${checker}" \
  "${creation_window_alternate}" <<'PYTHON_CREATION_WINDOW'
import importlib.util
import hashlib
import os
import sys

helper, staged, result, checker, alternate = sys.argv[1:]
spec = importlib.util.spec_from_file_location("product_usb_publisher", helper)
if spec is None or spec.loader is None:
    raise SystemExit(90)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_open = module.os.open


def racing_open(path, flags, mode=0o777, *, dir_fd=None):
    if path == os.path.basename(result) and flags & os.O_EXCL:
        os.unlink(staged)
        os.link(alternate, staged, follow_symlinks=False)
    if dir_fd is None:
        return real_open(path, flags, mode)
    return real_open(path, flags, mode, dir_fd=dir_fd)


module.os.open = racing_open
module.os.supports_dir_fd.add(racing_open)
with open(staged, "rb") as source:
    required_digest = hashlib.sha256(source.read()).hexdigest()
status = module.publish(staged, result, checker, required_digest)
raise SystemExit(0 if status == module.PUBLICATION_UNCERTAIN else 91)
PYTHON_CREATION_WINDOW
cmp -s "${creation_window_staged}" "${creation_window_alternate}"
cmp -s "${creation_window_result}" "${valid}"
! cmp -s "${creation_window_result}" "${creation_window_alternate}"
expect_checker_rejection \
  --directory "${creation_window_directory}" 'creation-window source replacement'

set +e
grep_failure_output="$(
  PATH="${work}/bin:${PATH}" \
  REAL_GREP="${real_grep}" \
  FAKE_GREP_CONTROL_FAILURE=1 \
    bash "${checker}" --log "${valid}" 2>&1
)"
grep_failure_status=$?
set -e
if [[ "${grep_failure_status}" -eq 0 ]]; then
  printf '%s\n' 'product USB evidence checker accepted a grep failure' >&2
  exit 1
fi
grep -Fq 'invalid product USB insertion evidence' <<<"${grep_failure_output}"

privacy="${work}/privacy.md"
sed 's/device label: MEIZU M20/device label: PASSWORD=PRODUCT-USB-PRIVATE-VALUE/' \
  "${valid}" >"${privacy}"
set +e
privacy_output="$(bash "${checker}" --log "${privacy}" 2>&1)"
privacy_status=$?
set -e
if [[ "${privacy_status}" -eq 0 ]]; then
  printf '%s\n' 'product USB evidence checker accepted sensitive content' >&2
  exit 1
fi
if [[ "${privacy_output}" == *'PRODUCT-USB-PRIVATE-VALUE'* ]]; then
  printf '%s\n' 'product USB evidence checker echoed sensitive content' >&2
  exit 1
fi

reject_mutation() {
  local name="$1" from="$2" to="$3"
  local invalid="${work}/${name}.md"
  sed "s/${from}/${to}/" "${valid}" >"${invalid}"
  if bash "${checker}" --log "${invalid}" >/dev/null 2>&1; then
    printf 'product USB evidence checker accepted mutation: %s\n' "${name}" >&2
    exit 1
  fi
}

reject_mutation elapsed 'elapsed ms: 2431' 'elapsed ms: 5001'
reject_mutation elapsed-overflow \
  'elapsed ms: 2431' \
  'elapsed ms: 9223372036854775808'
reject_mutation zero-elapsed 'elapsed ms: 2431' 'elapsed ms: 0'
reject_mutation dirty 'bundle source dirty: false' 'bundle source dirty: true'
reject_mutation override 'probe override: false' 'probe override: true'
reject_mutation revision \
  'bundle source revision: 1111111111111111111111111111111111111111' \
  'bundle source revision: 2222222222222222222222222222222222222222'
reject_mutation cdhash-case \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
reject_mutation cdhash-length \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
reject_mutation cdhash-short \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
reject_mutation cdhash-sha256-length \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
reject_mutation cdhash-nonhex \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: gbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
reject_mutation cdhash-empty \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: '
reject_mutation dynamic-requirement \
  'running code requirement verified: true' \
  'running code requirement verified: false'
reject_mutation profile \
  'evidence profile: m1-product-usb-insertion-v1' \
  'evidence profile: unknown'

duplicate="${work}/duplicate.md"
cp "${valid}" "${duplicate}"
printf '%s\n' 'status: failed' >>"${duplicate}"
if bash "${checker}" --log "${duplicate}" >/dev/null 2>&1; then
  printf '%s\n' 'product USB evidence checker accepted duplicate status' >&2
  exit 1
fi

sensitive="${work}/sensitive.md"
cp "${valid}" "${sensitive}"
printf '%s\n' 'notes: /Users/private/secret' >>"${sensitive}"
if bash "${checker}" --log "${sensitive}" >/dev/null 2>&1; then
  printf '%s\n' 'product USB evidence checker accepted sensitive content' >&2
  exit 1
fi

unknown="${work}/unknown-field.md"
cp "${valid}" "${unknown}"
printf '%s\n' 'notes: extra field' >>"${unknown}"
if bash "${checker}" --log "${unknown}" >/dev/null 2>&1; then
  printf '%s\n' 'product USB evidence checker accepted an unknown field' >&2
  exit 1
fi

printf '%s\n' 'product USB insertion evidence validator tests passed.'
printf '%s\n' '中文：产品 USB 插入证据校验器测试通过。'
