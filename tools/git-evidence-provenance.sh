#!/usr/bin/env bash

# Read Git provenance without inheriting caller Git/config/credential state.
# Callers decide whether a dirty but truthfully reported tree is acceptable.

readonly DROIDMATCH_OFFICIAL_GIT_URL='https://github.com/FoxBai/DroidMatch.git'
readonly DROIDMATCH_OFFICIAL_GIT_URL_NO_SUFFIX='https://github.com/FoxBai/DroidMatch'

droidmatch_git_layout() {
  local repository_root="$1" canonical_root dot_git git_dir common_dir_line
  canonical_root="$(cd "${repository_root}" && pwd -P)" || return 1
  dot_git="${canonical_root}/.git"
  if [[ -d "${dot_git}" && ! -L "${dot_git}" ]]; then
    git_dir="${dot_git}"
  elif [[ -f "${dot_git}" && ! -L "${dot_git}" ]]; then
    IFS= read -r common_dir_line <"${dot_git}" || return 1
    [[ "${common_dir_line}" == 'gitdir: '/* ]] || return 1
    git_dir="${common_dir_line#gitdir: }"
    git_dir="$(cd "${git_dir}" && pwd -P)" || return 1
  else
    return 1
  fi
  if [[ -f "${git_dir}/commondir" && ! -L "${git_dir}/commondir" ]]; then
    IFS= read -r common_dir_line <"${git_dir}/commondir" || return 1
    [[ -n "${common_dir_line}" ]] || return 1
    common_dir="$(cd "${git_dir}/${common_dir_line}" && pwd -P)" || return 1
  else
    common_dir="${git_dir}"
  fi
  printf '%s\n%s\n%s\n' "${canonical_root}" "${git_dir}" "${common_dir}"
}

droidmatch_evidence_git() {
  local repository_root="$1"
  local layout canonical_root git_dir common_dir
  shift
  layout="$(droidmatch_git_layout "${repository_root}")" || return 1
  canonical_root="$(/usr/bin/sed -n '1p' <<<"${layout}")"
  git_dir="$(/usr/bin/sed -n '2p' <<<"${layout}")"
  common_dir="$(/usr/bin/sed -n '3p' <<<"${layout}")"
  droidmatch_git_config_file_safe "${common_dir}/config" || return 1
  droidmatch_git_checkout_worktree_config_safe \
    "${git_dir}/config.worktree" || return 1
  /usr/bin/env -i \
    HOME=/var/empty \
    XDG_CONFIG_HOME=/var/empty \
    PATH=/usr/bin:/bin \
    LANG=C \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG=/dev/null \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_GRAFT_FILE=/dev/null \
    GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git --no-replace-objects \
      --git-dir="${git_dir}" --work-tree="${canonical_root}" \
      -c core.fsmonitor=false \
      -c core.fileMode=true \
      -c core.ignorecase=false \
      -c core.precomposeUnicode=false \
      -c core.hooksPath=/dev/null \
      "$@"
}

droidmatch_git_override_environment_absent() {
  local variable_name
  while IFS= read -r variable_name; do
    case "${variable_name}" in
      GIT_PAGER|GIT_TERMINAL_PROMPT)
        ;;
      GIT_*)
        return 1
        ;;
    esac
  done < <(builtin compgen -e)
}

droidmatch_git_config_file_safe() {
  local config_path="$1"
  local key_names key_name normalized value
  [[ ! -e "${config_path}" && ! -L "${config_path}" ]] && return 0
  [[ -f "${config_path}" && ! -L "${config_path}" ]] || return 1
  key_names="$(
    /usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      /usr/bin/git config --file "${config_path}" --no-includes \
        --name-only --list 2>/dev/null
  )" || return 1
  while IFS= read -r key_name; do
    [[ -n "${key_name}" ]] || continue
    normalized="$(printf '%s' "${key_name}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    case "${normalized}" in
      gc.auto)
        value="$(
          /usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin LANG=C LC_ALL=C \
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            /usr/bin/git config --file "${config_path}" --no-includes \
              --get-all "${key_name}" 2>/dev/null
        )" || return 1
        [[ "${value}" == 0 ]] || return 1
        ;;
      core.repositoryformatversion|core.filemode|core.bare|\
      core.logallrefupdates|core.ignorecase|core.precomposeunicode|\
      remote.origin.url|remote.origin.fetch|remote.origin.pushurl|branch.*)
        ;;
      *)
        return 1
        ;;
    esac
  done <<<"${key_names}"
}

droidmatch_git_checkout_worktree_config_safe() {
  local config_path="$1"
  local key_names key_name normalized value
  local sparse_checkout=0 sparse_checkout_cone=0 sparse_index=0
  [[ ! -e "${config_path}" && ! -L "${config_path}" ]] && return 0
  [[ -f "${config_path}" && ! -L "${config_path}" ]] || return 1
  key_names="$(
    /usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      /usr/bin/git config --file "${config_path}" --no-includes \
        --name-only --list 2>/dev/null
  )" || return 1
  while IFS= read -r key_name; do
    [[ -n "${key_name}" ]] || continue
    normalized="$(printf '%s' "${key_name}" \
      | /usr/bin/tr '[:upper:]' '[:lower:]')"
    value="$(
      /usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin LANG=C LC_ALL=C \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        /usr/bin/git config --file "${config_path}" --no-includes \
          --bool --get-all "${key_name}" 2>/dev/null
    )" || return 1
    [[ "${value}" == false ]] || return 1
    case "${normalized}" in
      core.sparsecheckout)
        [[ "${sparse_checkout}" -eq 0 ]] || return 1
        sparse_checkout=1
        ;;
      core.sparsecheckoutcone)
        [[ "${sparse_checkout_cone}" -eq 0 ]] || return 1
        sparse_checkout_cone=1
        ;;
      index.sparse)
        [[ "${sparse_index}" -eq 0 ]] || return 1
        sparse_index=1
        ;;
      *)
        return 1
        ;;
    esac
  done <<<"${key_names}"
  [[ "${sparse_checkout}" -eq 1 \
      && "${sparse_checkout_cone}" -eq 1 \
      && "${sparse_index}" -eq 1 ]]
}

droidmatch_git_source_contract() {
  local repository_root="$1"
  local canonical_root top_level replace_refs common_dir git_dir grafts_path
  local alternates_path attributes_path index_listing line flag
  canonical_root="$(cd "${repository_root}" && pwd -P)" || return 1
  top_level="$(droidmatch_evidence_git "${canonical_root}" \
    rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ "${top_level}" == "${canonical_root}" ]] || return 1
  replace_refs="$(droidmatch_evidence_git "${canonical_root}" \
    for-each-ref --format='%(refname)' refs/replace 2>/dev/null)" || return 1
  [[ -z "${replace_refs}" ]] || return 1
  local layout
  layout="$(droidmatch_git_layout "${canonical_root}")" || return 1
  git_dir="$(/usr/bin/sed -n '2p' <<<"${layout}")"
  common_dir="$(/usr/bin/sed -n '3p' <<<"${layout}")"
  grafts_path="${common_dir}/info/grafts"
  alternates_path="${common_dir}/objects/info/alternates"
  attributes_path="${common_dir}/info/attributes"
  [[ ! -e "${grafts_path}" && ! -L "${grafts_path}" ]] || return 1
  [[ ! -e "${alternates_path}" && ! -L "${alternates_path}" ]] || return 1
  [[ ! -e "${attributes_path}" && ! -L "${attributes_path}" ]] || return 1
  index_listing="$(droidmatch_evidence_git "${canonical_root}" \
    ls-files -v 2>/dev/null)" || return 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    flag="${line:0:1}"
    [[ "${flag}" != S && ! "${flag}" =~ ^[a-z]$ ]] || return 1
  done <<<"${index_listing}"
}

droidmatch_git_product_inputs_clean() {
  local repository_root="$1"
  local ignored_inputs tracked_inputs tracked_path expected_blob actual_blob
  ignored_inputs="$(droidmatch_evidence_git "${repository_root}" \
    ls-files --others --ignored --exclude-standard -- \
      .gitattributes .gitignore .gitmodules tools \
      mac/Package.swift mac/Package.resolved mac/Package@swift-*.swift \
      ':(top,glob)mac/.swiftpm' ':(top,glob)mac/.swiftpm/**' \
      mac/App mac/Plugins mac/Sources third_party/mac \
      2>/dev/null)" || return 1
  [[ -z "${ignored_inputs}" ]] || return 1
  tracked_inputs="$(droidmatch_evidence_git "${repository_root}" \
    ls-tree -r --name-only HEAD -- \
      .gitattributes .gitignore .gitmodules tools \
      mac/Package.swift mac/Package.resolved mac/Package@swift-*.swift \
      mac/.swiftpm \
      mac/App mac/Plugins mac/Sources third_party/mac 2>/dev/null)" || return 1
  [[ -n "${tracked_inputs}" ]] || return 1
  while IFS= read -r tracked_path; do
    [[ -n "${tracked_path}" ]] || continue
    expected_blob="$(droidmatch_evidence_git "${repository_root}" \
      rev-parse "HEAD:${tracked_path}" 2>/dev/null)" || return 1
    actual_blob="$(droidmatch_evidence_git "${repository_root}" \
      hash-object --no-filters -- "${repository_root}/${tracked_path}" \
      2>/dev/null)" || return 1
    [[ "${actual_blob}" == "${expected_blob}" ]] || return 1
  done <<<"${tracked_inputs}"
}

droidmatch_git_official_origin_contract() {
  local repository_root="$1" layout common_dir origin_urls push_urls
  layout="$(droidmatch_git_layout "${repository_root}")" || return 1
  common_dir="$(/usr/bin/sed -n '3p' <<<"${layout}")"
  origin_urls="$(
    /usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      /usr/bin/git config --file "${common_dir}/config" --no-includes \
        --get-all remote.origin.url 2>/dev/null
  )" || return 1
  [[ "${origin_urls}" == "${DROIDMATCH_OFFICIAL_GIT_URL}" \
      || "${origin_urls}" == "${DROIDMATCH_OFFICIAL_GIT_URL_NO_SUFFIX}" ]] \
    || return 1
  push_urls="$(
    /usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin LANG=C LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      /usr/bin/git config --file "${common_dir}/config" --no-includes \
        --get-all remote.origin.pushurl 2>/dev/null || true
  )"
  [[ -z "${push_urls}" \
      || "${push_urls}" == "${DROIDMATCH_OFFICIAL_GIT_URL}" \
      || "${push_urls}" == "${DROIDMATCH_OFFICIAL_GIT_URL_NO_SUFFIX}" ]]
}

droidmatch_git_official_repository_contract() {
  droidmatch_git_source_contract "$1" \
    && droidmatch_git_product_inputs_clean "$1" \
    && droidmatch_git_official_origin_contract "$1"
}

droidmatch_git_head() {
  local repository_root="$1" revision
  revision="$(droidmatch_evidence_git "${repository_root}" rev-parse HEAD \
    2>/dev/null)" || return 1
  [[ "${revision}" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "${revision}"
}

droidmatch_git_status() {
  droidmatch_evidence_git "$1" status --porcelain=v1 --untracked-files=all \
    2>/dev/null
}

droidmatch_refresh_official_main() {
  local repository_root="$1"
  local attempts="$2"
  local interval_seconds="$3"
  local attempt
  [[ "${attempts}" =~ ^[1-9][0-9]*$ \
      && "${interval_seconds}" =~ ^[0-9]+$ ]] || return 2
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if droidmatch_evidence_git "${repository_root}" \
        -c http.extraHeader= \
        -c http.https://github.com/.extraHeader= \
        -c http.proxy= \
        -c http.https://github.com/.proxy= \
        -c http.sslVerify=true \
        -c credential.helper= \
        fetch --quiet --no-tags --no-prune --recurse-submodules=no \
        "${DROIDMATCH_OFFICIAL_GIT_URL}" \
        refs/heads/main:refs/remotes/origin/main; then
      return 0
    fi
    if [[ "${attempt}" -lt "${attempts}" ]]; then
      printf 'WARNING official main refresh failed; retrying (%s/%s).\n' \
        "${attempt}" "${attempts}" >&2
      printf '警告：官方 main 刷新失败；正在重试（%s/%s）。\n' \
        "${attempt}" "${attempts}" >&2
      /bin/sleep "${interval_seconds}"
    fi
  done
  return 1
}
