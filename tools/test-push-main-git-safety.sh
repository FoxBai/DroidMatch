#!/usr/bin/env bash

set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-push-git-safety.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

remote="${test_root}/remote.git"
local_repo="${test_root}/local"
git init --bare --quiet "${remote}"
git init --quiet "${local_repo}"
git -C "${local_repo}" config user.name 'DroidMatch Test'
git -C "${local_repo}" config user.email 'test@droidmatch.invalid'
git -C "${local_repo}" config push.followTags true
git -C "${local_repo}" config push.recurseSubmodules on-demand

git -C "${local_repo}" commit --quiet --allow-empty -m 'base'
base_sha="$(git -C "${local_repo}" rev-parse HEAD)"
git -C "${local_repo}" commit --quiet --allow-empty \
  -m 'candidate' -m 'DroidMatch-Risk: R0'
candidate_sha="$(git -C "${local_repo}" rev-parse HEAD)"
git -C "${local_repo}" tag -a should-not-follow -m 'must remain local'
git -C "${local_repo}" remote add origin "${remote}"
git -C "${local_repo}" push --quiet --no-follow-tags --recurse-submodules=no \
  origin "${base_sha}:refs/heads/main"

hook_marker="${test_root}/pre-push-ran"
cat >"${local_repo}/.git/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
: >"${DROIDMATCH_PRE_PUSH_MARKER:?}"
exit 97
HOOK
chmod +x "${local_repo}/.git/hooks/pre-push"
hook_ref='codex/main-gate/no-local-hook'
DROIDMATCH_PRE_PUSH_MARKER="${hook_marker}" \
  git -C "${local_repo}" push --quiet --no-verify --no-follow-tags \
    --recurse-submodules=no origin "${candidate_sha}:refs/heads/${hook_ref}"
[[ ! -e "${hook_marker}" ]]
[[ "$(git --git-dir="${remote}" rev-parse "refs/heads/${hook_ref}")" == "${candidate_sha}" ]]
rm "${local_repo}/.git/hooks/pre-push"

unexpected_remote="${test_root}/unexpected.git"
git init --bare --quiet "${unexpected_remote}"
cat >"${local_repo}/.git/hooks/reference-transaction" <<'HOOK'
#!/usr/bin/env bash
if [[ "${1:-}" == committed ]]; then
  git push --quiet --no-verify "${DROIDMATCH_UNEXPECTED_REMOTE:?}" \
    HEAD:refs/heads/unexpected
fi
HOOK
chmod +x "${local_repo}/.git/hooks/reference-transaction"
git --git-dir="${remote}" update-ref refs/heads/fetch-hook-source "${candidate_sha}"
DROIDMATCH_UNEXPECTED_REMOTE="${unexpected_remote}" \
  git -C "${local_repo}" fetch --quiet "${remote}" \
    refs/heads/fetch-hook-source:refs/remotes/origin/unsafe-hook
[[ "$(git --git-dir="${unexpected_remote}" rev-parse refs/heads/unexpected)" == "${candidate_sha}" ]]
git --git-dir="${unexpected_remote}" update-ref -d refs/heads/unexpected
git -C "${local_repo}" -c core.hooksPath=/dev/null update-ref -d \
  refs/remotes/origin/unsafe-hook
DROIDMATCH_UNEXPECTED_REMOTE="${unexpected_remote}" \
  git -C "${local_repo}" -c core.hooksPath=/dev/null fetch --quiet \
    "${remote}" refs/heads/fetch-hook-source:refs/remotes/origin/safe-hook
! git --git-dir="${unexpected_remote}" rev-parse refs/heads/unexpected >/dev/null 2>&1
[[ "$(git -C "${local_repo}" rev-parse refs/remotes/origin/safe-hook)" == "${candidate_sha}" ]]
rm "${local_repo}/.git/hooks/reference-transaction"

fsmonitor_hook="${test_root}/fsmonitor-hook"
fsmonitor_marker="${test_root}/fsmonitor-ran"
cat >"${fsmonitor_hook}" <<'HOOK'
#!/usr/bin/env bash
: >"${DROIDMATCH_FSMONITOR_MARKER:?}"
exit 1
HOOK
chmod +x "${fsmonitor_hook}"
git -C "${local_repo}" config core.fsmonitor "${fsmonitor_hook}"
DROIDMATCH_FSMONITOR_MARKER="${fsmonitor_marker}" \
  git -C "${local_repo}" status --porcelain=v1 >/dev/null
[[ -e "${fsmonitor_marker}" ]]
rm "${fsmonitor_marker}"
DROIDMATCH_FSMONITOR_MARKER="${fsmonitor_marker}" \
  git -C "${local_repo}" -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null status --porcelain=v1 >/dev/null
[[ ! -e "${fsmonitor_marker}" ]]
git -C "${local_repo}" config --unset-all core.fsmonitor
rm "${fsmonitor_hook}"

candidate_ref='codex/main-gate/real-new'
candidate_output="$(git -C "${local_repo}" push --porcelain --no-follow-tags \
  --recurse-submodules=no --force-with-lease="refs/heads/${candidate_ref}:" \
  origin "${candidate_sha}:refs/heads/${candidate_ref}")"
expected_record=$'*\t'"${candidate_sha}:refs/heads/${candidate_ref}"$'\t[new branch]'
[[ "$(grep -Ec $'^[ *+=!-]\t' <<<"${candidate_output}")" -eq 1 ]]
grep -Fqx "${expected_record}" <<<"${candidate_output}"
[[ "$(git --git-dir="${remote}" rev-parse "refs/heads/${candidate_ref}")" == "${candidate_sha}" ]]
[[ "$(git --git-dir="${remote}" rev-parse refs/heads/main)" == "${base_sha}" ]]
! git --git-dir="${remote}" rev-parse refs/tags/should-not-follow >/dev/null 2>&1

same_ref='codex/main-gate/same-sha'
git -C "${local_repo}" push --quiet --no-follow-tags --recurse-submodules=no \
  origin "${candidate_sha}:refs/heads/${same_ref}"
same_output="$(git -C "${local_repo}" push --porcelain --no-follow-tags \
  --recurse-submodules=no --force-with-lease="refs/heads/${same_ref}:" \
  origin "${candidate_sha}:refs/heads/${same_ref}")"
grep -Fqx $'=\t'"${candidate_sha}:refs/heads/${same_ref}"$'\t[up to date]' \
  <<<"${same_output}"

other_ref='codex/main-gate/other-sha'
git -C "${local_repo}" push --quiet --no-follow-tags --recurse-submodules=no \
  origin "${base_sha}:refs/heads/${other_ref}"
if git -C "${local_repo}" push --quiet --no-follow-tags --recurse-submodules=no \
    --force-with-lease="refs/heads/${other_ref}:" origin \
    "${candidate_sha}:refs/heads/${other_ref}" >/dev/null 2>&1; then
  printf 'expect-absent lease accepted an existing different SHA\n' >&2
  exit 1
fi
[[ "$(git --git-dir="${remote}" rev-parse "refs/heads/${other_ref}")" == "${base_sha}" ]]

git -C "${local_repo}" push --quiet --no-follow-tags --recurse-submodules=no \
  --force-with-lease="refs/heads/${candidate_ref}:${candidate_sha}" origin \
  ":refs/heads/${candidate_ref}"
! git --git-dir="${remote}" rev-parse "refs/heads/${candidate_ref}" >/dev/null 2>&1

git -C "${local_repo}" commit --quiet --allow-empty -m 'advanced'
advanced_sha="$(git -C "${local_repo}" rev-parse HEAD)"
changed_ref='codex/main-gate/changed'
git -C "${local_repo}" push --quiet --no-follow-tags --recurse-submodules=no \
  origin "${candidate_sha}:refs/heads/${changed_ref}"
git -C "${local_repo}" push --quiet --no-follow-tags --recurse-submodules=no \
  origin "${advanced_sha}:refs/heads/${changed_ref}"
if git -C "${local_repo}" push --quiet --no-follow-tags --recurse-submodules=no \
    --force-with-lease="refs/heads/${changed_ref}:${candidate_sha}" origin \
    ":refs/heads/${changed_ref}" >/dev/null 2>&1; then
  printf 'exact cleanup lease deleted a changed ref\n' >&2
  exit 1
fi
[[ "$(git --git-dir="${remote}" rev-parse "refs/heads/${changed_ref}")" == "${advanced_sha}" ]]
! git --git-dir="${remote}" rev-parse refs/tags/should-not-follow >/dev/null 2>&1

second_remote="${test_root}/second-remote.git"
git init --bare --quiet "${second_remote}"
git -C "${local_repo}" config --add remote.origin.pushurl "${remote}"
git -C "${local_repo}" config --add remote.origin.pushurl "${second_remote}"
multi_ref='codex/main-gate/multiple-push-urls'
multi_output="$(git -C "${local_repo}" push --porcelain --no-follow-tags \
  --recurse-submodules=no origin "${candidate_sha}:refs/heads/${multi_ref}")"
[[ "$(grep -Ec $'^[ *+=!-]\t' <<<"${multi_output}")" -eq 2 ]]
[[ "$(git --git-dir="${remote}" rev-parse "refs/heads/${multi_ref}")" == "${candidate_sha}" ]]
[[ "$(git --git-dir="${second_remote}" rev-parse "refs/heads/${multi_ref}")" == "${candidate_sha}" ]]
! git --git-dir="${second_remote}" rev-parse refs/tags/should-not-follow >/dev/null 2>&1
git -C "${local_repo}" config --unset-all remote.origin.pushurl

redirect_root="${test_root}/redirect"
mkdir -p "${redirect_root}/FoxBai"
redirect_remote="${redirect_root}/FoxBai/DroidMatch.git"
git init --bare --quiet "${redirect_remote}"
git -C "${local_repo}" remote set-url origin 'alias:FoxBai/DroidMatch.git'
git -C "${local_repo}" config url.https://github.com/.insteadOf alias:
git -C "${local_repo}" config "url.file://${redirect_root}/.pushInsteadOf" \
  https://github.com/
rewritten_url="$(git -C "${local_repo}" remote get-url --push --all origin)"
[[ "${rewritten_url}" == 'https://github.com/FoxBai/DroidMatch.git' ]]
rewrite_ref='codex/main-gate/chained-url-rewrite'
git -C "${local_repo}" push --quiet --no-follow-tags --recurse-submodules=no \
  "${rewritten_url}" "${candidate_sha}:refs/heads/${rewrite_ref}"
[[ "$(git --git-dir="${redirect_remote}" rev-parse "refs/heads/${rewrite_ref}")" == "${candidate_sha}" ]]
git -C "${local_repo}" config --unset-all url.https://github.com/.insteadOf
git -C "${local_repo}" config --unset-all "url.file://${redirect_root}/.pushInsteadOf"
git -C "${local_repo}" remote set-url origin "${remote}"

git -C "${local_repo}" commit --quiet --allow-empty -m 'alias' -m 'foo: R0'
alias_sha="$(git -C "${local_repo}" rev-parse HEAD)"
alias_output="$(GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=trailer.foo.key \
  GIT_CONFIG_VALUE_0=DroidMatch-Risk \
  git -C "${local_repo}" show -s \
  --format='%(trailers:key=DroidMatch-Risk,only)' "${alias_sha}")"
[[ "${alias_output}" == 'DroidMatch-Risk: R0' ]]
GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=trailer.foo.key \
  GIT_CONFIG_VALUE_0=DroidMatch-Risk \
  git -C "${local_repo}" config --get-regexp '^trailer\.' >/dev/null

printf 'Real Git temporary-ref and trailer safety tests passed.\n'
printf '中文：真实 Git 临时 ref 与 trailer 安全测试通过。\n'
