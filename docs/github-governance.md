# GitHub Governance Baseline / GitHub 仓库治理基线

This document separates repository-hosting controls from code/CI evidence.
Phase A leaves GitHub without a required-pull-request rule because there is no
second maintainer, but repository policy permits no-PR integration only for R0
changes. R1 and R2 changes use a pull request even though Phase A cannot provide
independent human approval. R0 direct integration requires all three hosted
checks on the exact commit before `main` advances. R1/R2 pull requests require
the PR merge-candidate checks before merge; because squash creates a new commit,
the exact final `main` SHA receives its authoritative push checks after
integration and must pass before release readiness can be claimed.

本文把 GitHub 托管权限与代码/CI 证据分开。阶段 A 因不存在第二维护者而不在 GitHub
强制 PR，但仓库策略只允许 R0 变更不经 PR 集成；R1/R2 必须使用 PR，且不能把自审或
自动化审查表述为独立人工审批。R0 在 main 前移前验证精确 SHA；R1/R2 先验证 PR 合并
候选，squash 生成的最终 main SHA 则在集成后运行权威 push 门禁，门禁通过前不得声明
发布就绪。

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

Phase A has one accountable maintainer and no independent human reviewer. That
limitation must remain explicit: self-review, tests, physical-device evidence,
and automated or agent review can strengthen a decision, but none is independent
human approval.

阶段 A 只有一名承担责任的维护者，不存在独立人工审查。自审、测试、真机证据及自动化
或 Agent 审查可以提高可信度，但都不能被表述为独立人工审批。

Classify each change before integration:

| Class | Scope | Required integration and review |
|---|---|---|
| R0: low risk | Prose, comments, or formatting that cannot change executable behavior, tests/gates, evidence acceptance, security claims, or release state | Guarded direct integration or PR; written contract, final-diff self-review, and exact-candidate checks |
| R1: ordinary product change | Product/UI behavior, non-security refactoring, and tests or tooling that do not meet R2 | PR required; complete the template, run exact-candidate checks, and perform a fresh final-diff self-review |
| R2: security or release critical | Protocol/wire compatibility, authentication, cryptography, credentials, permissions, path handling, destructive file operations, persistence/atomicity, dependencies, signing, release admission, or evidence validators | PR required; all R1 controls plus a separate adversarial review pass and explicit release-review status |

R0 是不会影响可执行行为、测试门禁、证据接纳、安全声明或发布状态的纯文本、注释或
格式变更；R1 是不触及 R2 边界的普通产品、测试与工具变更；R2 覆盖协议、认证、密码与
凭据、权限、路径和破坏性文件操作、持久化/原子性、依赖、签名、发布准入及证据校验。

Apply the following controls:

- do not enable a hosted required-approval rule while no independent reviewer
  exists; repository policy still requires a PR for R1 and R2;
- require the PR template to record the governance phase, risk class, risk
  rationale, independent-human-review status, exact evidence, and open risks;
- require the Phase A maintainer to review the complete final diff in a fresh
  pass after implementation before the sole merge decision. Do not record the
  author's self-review as a GitHub approval;
- require R2 to receive a separate adversarial review in a fresh context.
  Automated or agent review is supporting evidence and must not be described as
  independent human approval;
- before a public beta or stable release, require independent human review of
  the unreviewed R2 changes since the last external review. Until then, artifacts
  remain single-maintainer M1/internal validation builds;
- require R0 direct integration to receive `spec`, `mac-skeleton`, and
  `android-skeleton` from `Spec and Skeleton Gates` on the exact candidate SHA
  before `main` accepts it;
- require R1/R2 pull requests to pass the required merge-candidate checks before
  squash merge, then require the resulting exact `main` push SHA to pass before
  any release-readiness claim. A failed exact-main run is fixed forward and is
  never hidden by the earlier PR result;
- use `tools/push-main-with-gates.sh --confirm-direct-main --attest-r0` so that
  the owner explicitly attests the R0 boundary; require every commit in the
  candidate range to persist `DroidMatch-Risk: R0` as a Git trailer. The SHA is
  pushed only after its local maintainer-contract preflight passes, then to a
  randomized temporary `codex/main-gate/*` ref. Tag following and submodule
  recursion are disabled. Git network commands use an empty hooks path, pushes
  disable verification hooks, and the worktree check disables the optional
  filesystem-monitor hook, closing repository-local hook side channels. The
  command first pins exactly one credential-free
  GitHub fetch endpoint and one effective push endpoint to the same repository
  identity and rejects Git URL rewrite configuration that could redirect a
  pinned endpoint. It repeats that fail-closed check immediately before every
  Git network operation and preserves the temporary ref if a later rewrite
  blocks cleanup; an expect-absent lease plus the sole exact porcelain creation
  record must prove ownership before the workflow's `push` trigger
  produces protection-eligible checks. Main and protection are re-read, the
  main update remains a non-forced fast-forward, and the unchanged owned ref is
  deleted only under an exact-SHA lease;
- keep conversation resolution enabled for changes that do use a PR;
- apply rules to administrators and disallow bypass, force-push, and deletion;
- keep signed-commit requirements optional until every maintainer has a verified
  signing workflow;
- enable automatic deletion of merged topic branches;
- prefer squash merge for a reviewable linear product history; retain another
  merge mode only if an active workflow needs it.

Risk classification remains a procedural owner control, not a semantic
fail-closed classifier: GitHub and the scripts cannot prove that a change labeled
R0 is actually low risk, and the Phase A hosting policy intentionally has no
required-PR rule. A manual bypass or false R0 classification violates this
contract. The command flag and Git trailers make the owner's assertion explicit
and persistent; they do not turn self-classification into independent review.

风险分级仍是单维护者的程序性约束，不是机器可证明的语义分类器。Phase A 的托管策略
没有强制 PR，脚本也无法证明标为 R0 的改动确属低风险；手动绕过或虚假分级都违反本
合同。命令参数与 Git trailer 只负责让声明明确且可追溯，不会把自我分类变成独立审查。

R0 direct integration is not independent review. The temporary-ref `push`
workflow is admission evidence; a manually dispatched run is not accepted for
this purpose. The local preflight catches known static inventory, wiring, and
takeover contract drift before remote mutation, but is neither admission
evidence nor a substitute for any hosted check. The workflow triggered by the
resulting `main` push is the authoritative exact-main CI evidence used by release
readiness. The repository command returns success only after both exact-SHA runs
pass and protection remains intact. A
protection transport/API read may be retried three times with a bounded delay;
an API-successful Phase A mismatch fails immediately. Read-only main refreshes
use the same bounded retry, while candidate creation is never retried. The main
fast-forward may be attempted at most three times only for an explicit transport
failure while the exact remote tip still equals the pre-gate base; Phase A and
that tip are revalidated before every extra write. An ambiguous candidate result
stops before CI discovery or main mutation and is not auto-cleaned, because a
visible same-SHA ref does not prove ownership. Only exact-SHA leased deletion of
a proven-owned temporary ref may repeat during cleanup, and a changed ref is
preserved. If the remote tip changes after candidate validation, restage and
rerun instead of bypassing or forcing the push.

阶段 A 不会制造虚假的“双人审批”。只有 R0 可以使用无 PR 的受保护直推；R1/R2 使用
PR，R2 还必须另行执行一轮对抗性审查，但自动化审查仍不等于独立人工审批。任何路径
都不允许绕过同一 SHA 三项检查、在远端已变化时强推，或把候选分支结果冒充最终
`main` push 的发布证据。保护读取的传输/API 失败最多有界重试三次；成功读取到
Phase A 偏差时立即拒绝，不会重试放行。只读 main 刷新采用相同的有界重试；候选创建
绝不重试。main 快进只有在错误明确属于传输故障、精确远端 tip 仍等于门禁前基线时才
最多尝试三次；每次额外写入前都重新核验 Phase A 和该 tip。临时候选结果有歧义时，在
查找 CI 或写 main 前停止，并且不会因远端显示相同 SHA 就自动删除，因为这不足以证明
所有权。只有已证明属于本次且未变化的临时 ref 才能用精确 SHA 删除租约重复清理；已
变化的 ref 必须保留。

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
- 2026-07-27: the repository owner clarified that DroidMatch still has one human
  maintainer. The repository contract now restricts no-PR integration to R0,
  requires PR-based fresh self-review for R1/R2, adds a separate adversarial pass
  for R2, and reserves the term independent approval for a real human reviewer.
  No GitHub hosting control changed in this documentation update.
