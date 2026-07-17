#!/usr/bin/env bash

# Sourced by build-mac-app.sh after its identity, rename, marker, and cleanup
# primitives are defined. These functions own only recovery state transitions.

recover_stale_transaction() {
  if ! transaction_layout_safe; then
    printf 'Existing App publication transaction is unsafe; refusing to continue.\n' >&2
    printf '中文：现有 App 发布事务不安全，拒绝继续。\n' >&2
    return 1
  fi
  local owner_pid owner_instance owner_status state candidate_identity output_identity
  owner_pid="$(read_marker owner-pid)" || return 1
  owner_instance="$(read_marker owner-instance)" || return 1
  state="$(read_marker state)" || return 1
  if ! [[ "${owner_pid}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Existing App publication transaction has an invalid owner.\n' >&2
    return 1
  fi
  if python3 "${repo_root}/tools/process_instance_identity.py" matches \
      "${owner_pid}" "${owner_instance}"; then
    printf 'Another App publication transaction is active.\n' >&2
    printf '中文：另一个 App 发布事务仍在运行。\n' >&2
    return 1
  else
    owner_status=$?
  fi
  if [[ "${owner_status}" -ne 1 ]]; then
    printf 'Existing App publication transaction has an invalid owner identity.\n' >&2
    printf '中文：现有 App 发布事务的拥有者身份无效。\n' >&2
    return 1
  fi
  canonical_output_safe || return 1

  case "${state}" in
    preparing|prepared)
      ;;
    swapping|verifying-swapped|rollback-required)
      candidate_identity="$(read_marker candidate-id)" || return 1
      output_identity="$(read_marker output-id)" || return 1
      if node_matches_identity "${transaction_root}/candidate.app" \
          "${candidate_identity}" \
          && node_matches_identity "${output_path}" "${output_identity}"; then
        : # The atomic swap had not happened, or rollback completed.
      elif node_matches_identity "${transaction_root}/candidate.app" \
          "${output_identity}" \
          && node_matches_identity "${output_path}" "${candidate_identity}" \
          && output_bundle_identity_safe "${transaction_root}/candidate.app" \
          && output_bundle_identity_safe "${output_path}"; then
        python3 "${repo_root}/tools/check-mac-app-not-running.py" "${output_path}" \
          || return 1
        swap_exact_directories "${transaction_root}/candidate.app" \
          "${output_path}" "${output_identity}" "${candidate_identity}" || return 1
        printf 'Recovered the previous App before post-publication validation completed.\n'
        printf '中文：发布后验证尚未完成，已恢复先前 App。\n'
      else
        printf 'Interrupted App publication has an inconsistent directory mapping.\n' >&2
        printf '中文：中断的 App 发布目录映射不一致。\n' >&2
        return 1
      fi
      ;;
    rolled-back)
      candidate_identity="$(read_marker candidate-id)" || return 1
      output_identity="$(read_marker output-id)" || return 1
      if ! node_matches_identity "${transaction_root}/candidate.app" \
          "${candidate_identity}" \
          || ! node_matches_identity "${output_path}" "${output_identity}"; then
        printf 'Interrupted App rollback has an inconsistent directory mapping.\n' >&2
        printf '中文：中断的 App 回滚目录映射不一致。\n' >&2
        return 1
      fi
      ;;
    swapped)
      candidate_identity="$(read_marker candidate-id)" || return 1
      output_identity="$(read_marker output-id)" || return 1
      if node_matches_identity "${transaction_root}/candidate.app" \
          "${output_identity}" \
          && node_matches_identity "${output_path}" "${candidate_identity}" \
          && output_bundle_identity_safe "${transaction_root}/candidate.app" \
          && output_bundle_identity_safe "${output_path}"; then
        printf 'Recovered a fully verified App published before interruption.\n'
        printf '中文：已恢复中断前完成发布且验证通过的 App。\n'
      else
        printf 'Verified App publication has an inconsistent directory mapping.\n' >&2
        printf '中文：已验证 App 发布的目录映射不一致。\n' >&2
        return 1
      fi
      ;;
    installing-new|verifying-installed-new)
      candidate_identity="$(read_marker candidate-id)" || return 1
      if [[ ! -e "${output_path}" && ! -L "${output_path}" ]] \
          && node_matches_identity "${transaction_root}/candidate.app" \
            "${candidate_identity}"; then
        :
      elif [[ ! -e "${transaction_root}/candidate.app" \
          && ! -L "${transaction_root}/candidate.app" ]] \
          && node_matches_identity "${output_path}" "${candidate_identity}"; then
        python3 "${repo_root}/tools/check-mac-app-not-running.py" "${output_path}" \
          || return 1
        install_exact_directory "${output_path}" \
          "${transaction_root}/candidate.app" "${candidate_identity}" || return 1
        printf 'Withdrew an unverified first App publication after interruption.\n'
        printf '中文：中断后已撤回尚未验证的首次 App 发布。\n'
      else
        printf 'Interrupted first App publication is inconsistent.\n' >&2
        printf '中文：中断的首次 App 发布状态不一致。\n' >&2
        return 1
      fi
      ;;
    installed-new)
      candidate_identity="$(read_marker candidate-id)" || return 1
      if [[ ! -e "${transaction_root}/candidate.app" \
          && ! -L "${transaction_root}/candidate.app" ]] \
          && node_matches_identity "${output_path}" "${candidate_identity}" \
          && output_bundle_identity_safe "${output_path}"; then
        printf 'Recovered a fully verified first App publication.\n'
        printf '中文：已恢复验证通过的首次 App 发布。\n'
      else
        printf 'Verified first App publication is inconsistent.\n' >&2
        printf '中文：已验证的首次 App 发布状态不一致。\n' >&2
        return 1
      fi
      ;;
    *)
      printf 'Existing App publication transaction has an unknown state.\n' >&2
      printf '中文：现有 App 发布事务状态未知。\n' >&2
      return 1
      ;;
  esac
  remove_transaction_tree
}

rollback_owned_publication() {
  local state candidate_identity output_identity
  state="$(read_marker state 2>/dev/null)" || return 1
  case "${state}" in
    swapping|verifying-swapped)
      candidate_identity="$(read_marker candidate-id 2>/dev/null)" || return 1
      output_identity="$(read_marker output-id 2>/dev/null)" || return 1
      if node_matches_identity "${transaction_root}/candidate.app" \
          "${output_identity}" \
          && node_matches_identity "${output_path}" "${candidate_identity}"; then
        write_transaction_state rollback-required || return 1
        swap_exact_directories "${transaction_root}/candidate.app" \
          "${output_path}" "${output_identity}" "${candidate_identity}" \
          || return 1
        write_transaction_state rolled-back || return 1
        printf 'Restored the previous DroidMatch App after publication failure.\n' >&2
        printf '中文：发布失败后已恢复先前的 DroidMatch App。\n' >&2
      elif node_matches_identity "${transaction_root}/candidate.app" \
          "${candidate_identity}" \
          && node_matches_identity "${output_path}" "${output_identity}"; then
        :
      else
        return 1
      fi
      ;;
    installing-new|verifying-installed-new)
      candidate_identity="$(read_marker candidate-id 2>/dev/null)" || return 1
      if node_matches_identity "${transaction_root}/candidate.app" \
            "${candidate_identity}"; then
        :
      elif [[ ! -e "${transaction_root}/candidate.app" \
          && ! -L "${transaction_root}/candidate.app" ]] \
          && node_matches_identity "${output_path}" "${candidate_identity}"; then
        install_exact_directory "${output_path}" \
          "${transaction_root}/candidate.app" "${candidate_identity}" || return 1
        printf 'Withdrew the first DroidMatch App after validation failure.\n' >&2
        printf '中文：验证失败后已撤回首次 DroidMatch App。\n' >&2
      else
        return 1
      fi
      ;;
    *)
      ;;
  esac
}
