#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${repo_root}/tools/git-evidence-provenance.sh"

droidmatch_git_source_contract "${repo_root}"
droidmatch_git_official_origin_contract "${repo_root}"

if (
  export GIT_INDEX_FILE=/private/tmp/untrusted-index
  droidmatch_git_override_environment_absent
); then
  printf '%s\n' 'Git provenance accepted a caller index override.' >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
repository="${work}/repository"
/usr/bin/git init -q "${repository}"
/usr/bin/git -C "${repository}" remote add origin \
  "${DROIDMATCH_OFFICIAL_GIT_URL}"
mkdir -p "${repository}/mac/Sources" "${repository}/tools"
printf '%s\n' 'first' >"${repository}/mac/Sources/Base.swift"
printf '%s\n' 'helper' >"${repository}/tools/helper.py"
printf '%s\n' '// swift-tools-version: 6.0' >"${repository}/mac/Package.swift"
/usr/bin/git -C "${repository}" add .
commit_environment=(
  GIT_AUTHOR_NAME=DroidMatch GIT_AUTHOR_EMAIL=noreply@example.invalid
  GIT_COMMITTER_NAME=DroidMatch GIT_COMMITTER_EMAIL=noreply@example.invalid
)
/usr/bin/env "${commit_environment[@]}" \
  /usr/bin/git -C "${repository}" commit -qm first
printf '%s\n' 'second' >>"${repository}/mac/Sources/Base.swift"
/usr/bin/git -C "${repository}" add mac/Sources/Base.swift
/usr/bin/env "${commit_environment[@]}" \
  /usr/bin/git -C "${repository}" commit -qm second

droidmatch_git_source_contract "${repository}"
droidmatch_git_official_repository_contract "${repository}"
tools_tree="$(/usr/bin/git -C "${repository}" rev-parse HEAD:tools)"
tools_tree_object="${repository}/.git/objects/${tools_tree:0:2}/${tools_tree:2}"
mv "${tools_tree_object}" "${work}/missing-tools-tree"
if droidmatch_git_product_inputs_clean "${repository}" 2>/dev/null; then
  printf '%s\n' 'Git provenance accepted a failed product-tree enumeration.' >&2
  exit 1
fi
mv "${work}/missing-tools-tree" "${tools_tree_object}"
/usr/bin/git -C "${repository}" config --local gc.auto 0
droidmatch_git_source_contract "${repository}"
/usr/bin/git -C "${repository}" config --local gc.auto 1
if droidmatch_git_source_contract "${repository}"; then
  printf '%s\n' 'Git provenance accepted an unsafe checkout gc.auto value.' >&2
  exit 1
fi
/usr/bin/git -C "${repository}" config --local gc.auto 0
/usr/bin/git -C "${repository}" remote set-url origin \
  "${DROIDMATCH_OFFICIAL_GIT_URL_NO_SUFFIX}"
droidmatch_git_official_origin_contract "${repository}"
/usr/bin/git -C "${repository}" remote set-url origin \
  "${DROIDMATCH_OFFICIAL_GIT_URL}"

printf '%s\n' 'mac/Sources/Injected.swift' \
  >>"${repository}/.git/info/exclude"
printf '%s\n' 'ignored product source' \
  >"${repository}/mac/Sources/Injected.swift"
if droidmatch_git_product_inputs_clean "${repository}"; then
  printf '%s\n' 'Git provenance accepted an ignored product source.' >&2
  exit 1
fi
rm "${repository}/mac/Sources/Injected.swift"
: >"${repository}/.git/info/exclude"

case_probe="${work}/case-sensitive-probe"
mkdir "${case_probe}"
: >"${case_probe}/A"
: >"${case_probe}/a"
if [[ ! "${case_probe}/A" -ef "${case_probe}/a" ]]; then
  printf '%s\n' 'tracked case' >"${repository}/mac/Sources/CaseProbe.swift"
  /usr/bin/git -C "${repository}" add mac/Sources/CaseProbe.swift
  /usr/bin/env "${commit_environment[@]}" \
    /usr/bin/git -C "${repository}" commit -qm case-probe
  /usr/bin/git -C "${repository}" config --local core.ignorecase true
  printf '%s\n' 'hidden case variant' >"${repository}/mac/Sources/caseprobe.swift"
  case_alias_status="$(droidmatch_git_status "${repository}")"
  if [[ -z "${case_alias_status}" ]]; then
    printf '%s\n' 'Git provenance accepted a case-aliased product source.' >&2
    exit 1
  fi
  rm "${repository}/mac/Sources/caseprobe.swift"
fi

/usr/bin/git -C "${repository}" update-index --assume-unchanged \
  mac/Sources/Base.swift
if droidmatch_git_source_contract "${repository}"; then
  printf '%s\n' 'Git provenance accepted assume-unchanged input.' >&2
  exit 1
fi
/usr/bin/git -C "${repository}" update-index --no-assume-unchanged \
  mac/Sources/Base.swift
/usr/bin/git -C "${repository}" update-index --skip-worktree \
  mac/Sources/Base.swift
if droidmatch_git_source_contract "${repository}"; then
  printf '%s\n' 'Git provenance accepted skip-worktree input.' >&2
  exit 1
fi
/usr/bin/git -C "${repository}" update-index --no-skip-worktree \
  mac/Sources/Base.swift

/usr/bin/git -C "${repository}" replace HEAD~1 HEAD
if droidmatch_git_source_contract "${repository}"; then
  printf '%s\n' 'Git provenance accepted a replace ref.' >&2
  exit 1
fi
/usr/bin/git -C "${repository}" replace -d HEAD~1 >/dev/null

printf '%s\n' 'invalid graft' >"${repository}/.git/info/grafts"
if droidmatch_git_source_contract "${repository}"; then
  printf '%s\n' 'Git provenance accepted a graft file.' >&2
  exit 1
fi
rm "${repository}/.git/info/grafts"

cp "${repository}/.git/config" "${work}/config.backup"
printf '%s\n' '[include]' '  path = /private/tmp/untrusted.gitconfig' \
  >>"${repository}/.git/config"
if droidmatch_git_source_contract "${repository}"; then
  printf '%s\n' 'Git provenance accepted a local config include.' >&2
  exit 1
fi
cp "${work}/config.backup" "${repository}/.git/config"

worktree_config="${repository}/.git/config.worktree"
write_checkout_worktree_config() {
  printf '%s\n' \
    '[core]' \
    '  sparseCheckout = false' \
    '  sparseCheckoutCone = false' \
    '[index]' \
    '  sparse = false' \
    >"${worktree_config}"
}
assert_worktree_config_rejected() {
  local reason="$1"
  if droidmatch_git_checkout_worktree_config_safe "${worktree_config}"; then
    printf 'Git provenance accepted %s.\n' "${reason}" >&2
    exit 1
  fi
}

write_checkout_worktree_config
droidmatch_git_source_contract "${repository}"
/usr/bin/git config --file "${worktree_config}" \
  core.sparseCheckout true
assert_worktree_config_rejected 'active sparse checkout config'
write_checkout_worktree_config
/usr/bin/git config --file "${worktree_config}" \
  evidence.untrusted true
assert_worktree_config_rejected 'extra worktree-local config'
write_checkout_worktree_config
/usr/bin/git config --file "${worktree_config}" --unset index.sparse
assert_worktree_config_rejected 'incomplete checkout worktree config'
write_checkout_worktree_config
/usr/bin/git config --file "${worktree_config}" --add \
  core.sparseCheckout false
assert_worktree_config_rejected 'duplicate checkout worktree config'
write_checkout_worktree_config
printf '%s\n' '[include]' '  path = /private/tmp/untrusted.gitconfig' \
  >>"${worktree_config}"
assert_worktree_config_rejected 'included worktree-local config'
printf '%s\n' '[malformed' >"${worktree_config}"
assert_worktree_config_rejected 'malformed worktree-local config'
write_checkout_worktree_config
mv "${worktree_config}" "${worktree_config}.target"
ln -s "${worktree_config}.target" "${worktree_config}"
assert_worktree_config_rejected 'symlinked worktree-local config'
rm "${worktree_config}" "${worktree_config}.target"

/usr/bin/git -C "${repository}" remote set-url origin \
  https://github.com/example/fork.git
droidmatch_git_source_contract "${repository}"
if droidmatch_git_official_origin_contract "${repository}"; then
  printf '%s\n' 'Git provenance accepted a fork as the official repository.' >&2
  exit 1
fi

grep -Fq '/usr/bin/env -i' "${repo_root}/tools/git-evidence-provenance.sh"
grep -Fq "${DROIDMATCH_OFFICIAL_GIT_URL}" \
  "${repo_root}/tools/git-evidence-provenance.sh"
grep -Fq 'fetch --quiet --no-tags --no-prune --recurse-submodules=no' \
  "${repo_root}/tools/git-evidence-provenance.sh"

set +e
evidence_builder_output="$(
  /bin/bash "${repo_root}/tools/build-mac-app.sh" \
    --evidence-ready --sandboxed --adb-executable /bin/echo 2>&1
)"
evidence_builder_status=$?
set -e
[[ "${evidence_builder_status}" -eq 2 ]]
grep -Fq 'Evidence-ready builds require release' <<<"${evidence_builder_output}"

set +e
/usr/bin/env -i \
  HOME=/var/empty TMPDIR=/private/tmp \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C \
  PYTHONDONTWRITEBYTECODE=0 DROIDMATCH_EVIDENCE_BUILD_CLEAN=1 \
  /bin/bash --noprofile --norc -p "${repo_root}/tools/build-mac-app.sh" \
    --evidence-ready --sandboxed --adb-executable /bin/echo \
    >/dev/null 2>&1
unisolated_builder_status=$?
set -e
[[ "${unisolated_builder_status}" -eq 1 ]]

printf '%s\n' 'Git evidence provenance tests passed.'
printf '%s\n' '中文：Git 证据来源边界测试通过。'
