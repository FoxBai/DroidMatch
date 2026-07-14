# GitHub Governance Baseline / GitHub 仓库治理基线

This document separates repository-hosting controls from code/CI evidence.
Phase A permits the repository owner to fast-forward `main` without a pull
request, but only after the exact candidate commit has all three required hosted
checks. A green run for another commit or event is not equivalent evidence.

本文把 GitHub 托管权限与代码/CI 证据分开；阶段 A 允许仓库所有者不经 PR 快进
`main`，但候选提交的同一 SHA 必须先通过三项托管检查，其他提交或事件的绿色结果不能替代。

## Current observed state / 当前观测状态

API verification against `main` at the observed tip
(`33db11bfba1615ce7b1c4d47c27c1a336f041044`) on 2026-07-15 found:

- public repository, default branch `main`;
- `main` protected with up-to-date `spec`, `mac-skeleton`, and
  `android-skeleton` checks required;
- no required-pull-request rule, by the owner's explicit direct-integration
  decision; conversation resolution remains enabled when a PR is used;
- linear history enforced;
- administrator enforcement enabled; force-push and branch deletion disabled;
- no repository ruleset;
- squash is the only enabled merge mode;
- merged topic branches are deleted automatically;
- secret scanning and secret-scanning push protection enabled; Dependabot
  security updates disabled.

This observation records the Phase A direct-integration change as well as the
controls that remain in force. Security-scanning settings are hosting
observations, not a substitute for the required checks or release checklist.

在 2026-07-15 观测到的 `main` 提交（`33db11bfba1615ce7b1c4d47c27c1a336f041044`）上，
仓库所有者明确要求并授权移除强制 PR；三项检查、管理员约束、线性历史、禁强推/删除、
Secret Scanning 与推送保护仍保留。Dependabot 安全更新仍未开启。这些托管层观测不替代
仓库必需检查或发布清单。

This is a dated observation, not a permanent claim. Recheck before release or
after any ownership change:

```text
gh api repos/FoxBai/DroidMatch/branches/main/protection
gh api repos/FoxBai/DroidMatch/rulesets
gh api repos/FoxBai/DroidMatch --jq '{default_branch,delete_branch_on_merge}'
```

## Phase A: safe single-owner baseline / 阶段 A：单一所有者安全基线

Apply only with explicit repository-administration authorization:

- do not require a pull request while the owner has explicitly selected direct
  integration and no independent reviewer exists;
- require `spec`, `mac-skeleton`, and `android-skeleton` from
  `Spec and Skeleton Gates` on the exact candidate SHA before `main` accepts it;
- use `tools/push-main-with-gates.sh --confirm-direct-main` so that SHA is pushed
  to a unique temporary `codex/main-gate/*` ref, the workflow's `push` trigger
  produces protection-eligible checks, main and protection are re-read, the
  update remains a non-forced fast-forward, and the owned ref is deleted;
- keep conversation resolution enabled for changes that do use a PR;
- apply rules to administrators and disallow bypass, force-push, and deletion;
- keep signed-commit requirements optional until every maintainer has a verified
  signing workflow;
- enable automatic deletion of merged topic branches;
- prefer squash merge for a reviewable linear product history; retain another
  merge mode only if an active workflow needs it.

Direct integration is not independent review. The temporary-ref `push` workflow
is admission evidence; a manually dispatched run is not accepted for this
purpose. The workflow triggered by the resulting `main` push is the authoritative
exact-main CI evidence used by release readiness. The repository command returns
success only after both exact-SHA runs pass and protection remains intact. A
protection transport/API read may be retried three times with a bounded delay;
an API-successful Phase A mismatch fails immediately. Read-only main refreshes
use the same bounded retry, but candidate creation and the main fast-forward are
never retried; only idempotent deletion of the owned temporary ref may repeat
during cleanup. If the remote tip changes after candidate validation, restage
and rerun instead of bypassing or forcing the push.

阶段 A 不会制造虚假的“双人审批”；它允许无 PR 直推，但不允许未经同一 SHA 三项检查、
在远端已变化时强推，或把候选分支结果冒充最终 `main` push 的发布证据。保护读取的
传输/API 失败最多有界重试三次；成功读取到 Phase A 偏差时立即拒绝，不会重试放行。
只读 main 刷新采用相同的有界重试；候选创建与 main 快进绝不重试，只有自有临时 ref
的幂等删除可在清理时重复。

## Phase B: second-maintainer baseline / 阶段 B：第二维护者基线

After a real second maintainer has accepted responsibility:

- add component-specific CODEOWNERS entries instead of only the repository-wide owner;
- require one approval and CODEOWNER review for owned paths;
- dismiss stale approvals after new commits and require approval of the latest push;
- assign release/tag/package authority to at least two people with least privilege;
- rehearse one release handoff where the second maintainer runs the gates and
  verifies artifacts without hidden local credentials or instructions.

## Change record / 变更记录

Whenever GitHub controls change, record the date, actor, exact settings, rollback
path, and the first integration that demonstrates the required checks. Never put
tokens, signing credentials, or private organization details in this repository.

- 2026-07-11: the repository owner authorized and Codex applied Phase A to
  `main`. Roll back through the branch-protection and repository settings APIs,
  preserving a dated before/after record. [PR #1](https://github.com/FoxBai/DroidMatch/pull/1)
  is the first change used to demonstrate all three required checks.
- 2026-07-14: Codex revalidated the Phase A controls and repository security
  settings at the observed main tip `9abd67b`; no hosting control change was
  made. The SHA is evidence for that observation, not a permanent current-tip
  claim.
  The observation should be repeated after the next repository-administration
  change.
- 2026-07-15: at the repository owner's explicit request to push directly to
  `main`, Codex removed only the required-pull-request rule. The three strict
  checks, administrator enforcement, conversation resolution, linear history,
  force-push/deletion bans, merge-mode baseline, and secret protections remain.
  Roll back by restoring required pull requests with zero approvals through the
  branch-protection API. The first direct integration is the repository change
  carrying this record and must retain its exact-SHA pre-push and exact-main
  hosted runs in GitHub Actions.
