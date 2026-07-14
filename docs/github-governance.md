# GitHub Governance Baseline / GitHub 仓库治理基线

This document separates repository-hosting controls from code/CI evidence. A
green workflow alone cannot prevent a direct push; the hosting controls below
make the required workflow enforceable.

本文把 GitHub 托管权限与代码/CI 证据分开；仅有绿色 CI 不能阻止直接推送，以下托管控制会强制执行所需流程。

## Current observed state / 当前观测状态

API verification against `main` at the observed tip
(`9abd67b098d55fd0f18b48989020dbaeef57ec34`) on 2026-07-14 found:

- public repository, default branch `main`;
- `main` protected with up-to-date `spec`, `mac-skeleton`, and
  `android-skeleton` checks required;
- pull requests required with zero approvals, conversation resolution, and
  linear history enforced;
- administrator enforcement enabled; force-push and branch deletion disabled;
- no repository ruleset;
- squash is the only enabled merge mode;
- merged topic branches are deleted automatically;
- secret scanning and secret-scanning push protection enabled; Dependabot
  security updates disabled.

This recheck confirms the Phase A controls are still present after the current
mainline integration. Security-scanning settings are hosting observations, not
a substitute for the repository's required checks or the release checklist.

在 2026-07-14 观测到的 `main` 提交（`9abd67b098d55fd0f18b48989020dbaeef57ec34`）上
复核发现：上述阶段 A 控制仍然存在；Secret Scanning 与推送保护已开启，Dependabot
安全更新未开启。这些是 GitHub 托管层观测，不替代仓库必需检查或发布清单。

This is a dated observation, not a permanent claim. Recheck before release or
after any ownership change:

```text
gh api repos/FoxBai/DroidMatch/branches/main/protection
gh api repos/FoxBai/DroidMatch/rulesets
gh api repos/FoxBai/DroidMatch --jq '{default_branch,delete_branch_on_merge}'
```

## Phase A: safe single-owner baseline / 阶段 A：单一所有者安全基线

Apply only with explicit repository-administration authorization:

- require pull requests for `main`, with zero required approvals while no
  independent reviewer exists;
- require the `spec`, `mac-skeleton`, and `android-skeleton` status checks from
  `Spec and Skeleton Gates` to pass on an up-to-date branch;
- require conversation resolution;
- apply rules to administrators and disallow bypass, force-push, and deletion;
- keep signed-commit requirements optional until every maintainer has a verified
  signing workflow;
- enable automatic deletion of merged topic branches;
- prefer squash merge for a reviewable linear product history; retain another
  merge mode only if an active workflow needs it.

Zero approvals is not independent review. It only ensures changes pass through a
PR and hosted checks instead of bypassing them.

阶段 A 不会制造虚假的“双人审批”，但会阻止绕过 PR 和 CI 直接写入 `main`。

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
path, and a link to the first PR that demonstrates the required checks. Never put
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
