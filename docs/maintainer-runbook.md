# Maintainer Runbook / 维护者运行手册

This is the shortest safe path from a fresh checkout to an evidence-backed
handoff or release decision. It complements, rather than replaces, the detailed
architecture and M1 testing documents.

本文给出从全新检出到可交接、可判断是否发布的最短安全路径；详细设计仍以架构与 M1 测试文档为准。

## 1. Establish the current truth / 确认当前事实

1. Read `README.md`, `docs/m1-status.md`, and `docs/technical-debt.md`.
2. Run `git status --short` and preserve unrelated local changes.
3. Run `bash tools/check-env.sh --all`, then `bash tools/check-m1-skeleton.sh`.
4. Check the latest GitHub Actions run. A green hosted run is build evidence,
   not physical-device or release-signing evidence.
5. Read `docs/github-governance.md` and recheck branch protection before release;
   Phase A makes the three hosted skeleton checks mandatory on the exact
   up-to-date candidate SHA before an owner fast-forwards `main` without a PR.

不要从历史 session note 或 fixture 推断当前能力；它们只能证明当时发生过什么。

## 2. Ownership map / 所有权地图

| Change | Primary source | Required companion evidence |
|---|---|---|
| Wire schema | `proto/v1/` | Both runtimes, protocol docs, compatibility tests |
| Mac transport/session | `mac/Sources/DroidMatchCore/Async*` | Swift tests, cancellation/timeout/recovery tests |
| Mac product UI | `DroidMatchPresentation`, `DroidMatchApp` | MainActor tests, localized App build |
| Android endpoint | `android/app/src/main/` | JVM tests, APK/test APK build, lint |
| Provider/permission behavior | Android provider layer | Permission tests plus explicit device matrix case |
| Release/evidence claims | `docs/m1-status*.md` | Redacted archived run or signed artifact proof |

One change owner should carry a behavior through code, tests, live docs, and
evidence. Generated protobuf, fixture logs, and UI must never become competing
sources of truth.

When a pull request is used, `.github/pull_request_template.md` records its owned
files, preserved invariants, exact evidence, skipped physical/signing work, and
next action. Owner direct integration records the same contract in the commit
and handoff, then runs
`tools/push-main-with-gates.sh --confirm-direct-main`. The command owns the
local maintainer-contract preflight plus temporary-ref/exact-SHA sequence
documented in `docs/ci-cd.md`; do not replace it with a partial copy of the
underlying commands. The preflight rejects known static takeover/inventory drift
before any remote push but does not replace hosted admission. Either path must
leave takeover state explicit instead of relying on one maintainer's memory.

`AsyncFramedTcpSession` is the only production `Network.framework` owner.
`ProcessRunner` is the only permitted semaphore boundary, because it runs bounded
subprocess work that callers must isolate on a private queue. `Task.detached` is
not an accepted way to hide blocking work; the maintainer contract gate enforces
these rules.

## 3. Physical-device safety / 真机安全边界

`adb devices -l` is read-only. Everything beyond discovery is opt-in. Before a
device script, record the exact serial, confirm it is disposable test hardware,
identify written destinations/permissions, and define cleanup. Never install,
pair, transfer, revoke, or mutate permissions merely because a device is online.

真机脚本结束后检查 forward、测试服务、临时文件和权限是否清理；只有脱敏日志可以进入 `fixtures/m1-runs/`。

New ordinary evidence must be published by the known
`m1-device-smoke-v1` runner path. Do not hand-author a substitute, edit one of
the 89 unprofiled historical fixtures, or recompute `legacy-v0.sha256` to accept
changed bytes. A special attended workflow needs its own versioned profile and
validator before archival, and `failed-diagnostic` never means that a device gate
passed. A clean, rebuilt, full-revision run is required for `device-evidence`;
dirty, unknown-provenance, or reused-APK passes remain `diagnostic-only`. The
checker verifies privacy, provenance recording, semantic consistency, and
review-visible legacy byte integrity; it does not cryptographically prove physical
execution or move its in-repository manifest outside normal code review.

Slot A throughput evidence must use `tools/run-m1-throughput-gate.sh`. Its
preflight maps only the selected serial to the bounded macOS USB registry and
refuses missing, duplicate, malformed, or hubbed paths before build/device writes.
It then monitors every 0.5 seconds through the child runner and rechecks before
the final no-clobber publication. A pre-created failure guard plus HUP/INT/TERM
process-group cleanup makes topology refusal, monitor failure, and interruption
suppress failed-diagnostic publication. The wrapper removes the guard only after
the supervisor reaps the child process group, exits successfully, preserves the
original guard identity, and writes a valid exact one-line child-status record;
never bypass that refusal with a generic smoke run or hand-authored fixture.

Slot A 吞吐证据必须使用 `tools/run-m1-throughput-gate.sh`。其预检只把所选 serial
映射到有大小上限的 macOS USB 注册表；缺失、重复、格式错误或经过 Hub 的路径都会在
构建/写设备前被拒绝。底层 runner 全程每 0.5 秒复验，发布前再验；任一次拒绝都禁止
失败诊断发布。只有 supervisor 回收完整子进程组、成功退出、保持原 guard 身份，且私有
子进程状态是严格单行有效记录后，wrapper 才会删除预创建 failure guard；HUP/INT/TERM
会终止并回收整个子进程组；不得用普通 smoke
或手写 fixture 绕过。

新增普通证据必须由已知的 `m1-device-smoke-v1` runner 路径发布。不得手写替代日志、
编辑 89 份无 profile 历史 fixture，或通过重算 `legacy-v0.sha256` 接受已变化的字节。
特殊人工流程必须先具备独立版本化 profile 与 validator，`failed-diagnostic` 也绝不表示
设备门槛已通过。只有 clean、rebuilt、完整 revision 的运行才是 `device-evidence`；
dirty、unknown provenance 或 reused APK 的通过运行仍是 `diagnostic-only`。checker 校验
隐私、provenance 记录、语义一致性和 review-visible 历史字节完整性，但不对物理执行
提供密码学证明，也不会让仓库内 manifest 脱离正常代码审查。

The SHARP 704SH launcher layout is one such special workflow. Diagnostic runs
omit evidence options. Archival requires `m1-android-launcher-layout-v1` through
`tools/run-704sh-layout-instrumentation.sh --expected-main-sha ... --result-log
fixtures/android-layout/<new-name>.md` on clean current `origin/main`. Never
hand-author the record or retain raw instrumentation output. A valid persistent
byte-identical result/`.commit` pair proves only the exact v2 layout assertion
set and verified test-package cleanup; it does not close throughput, USB
insertion, TalkBack, signing, or notarization gates.

SHARP 704SH 启动器布局属于上述特殊流程。普通诊断不提供证据参数；归档必须在 clean
current `origin/main` 上，通过 `tools/run-704sh-layout-instrumentation.sh
--expected-main-sha ... --result-log fixtures/android-layout/<新名称>.md` 执行
`m1-android-launcher-layout-v1`。不得手写记录或保留原始 instrumentation 输出。
逐字节一致且持久化的 result/`.commit` 文件对只证明精确 v2 布局断言与测试包清理，
不能关闭吞吐、USB 插入、TalkBack、签名或公证门禁。

## 4. Incident triage / 故障处理

1. Stop new writes and preserve the first failing command/output.
2. Classify the boundary: environment, ADB, frame, handshake/auth, provider,
   checkpoint/recovery, presentation, or packaging.
3. Reproduce with the narrowest deterministic local test before a device rerun.
4. For transfer incidents, preserve sidecar/partial metadata without exposing
   user paths or contents; never silently restart a mismatched resume. A
   `commitUncertain` result means the fixed `.pending`/`.removing` marker or
   download publication scene must be preserved for review, not deleted/retried.
5. For App/DMG publication incidents, do not manually remove a stable
   `.publication-transaction`. Re-run the owning build script: it will recover a
   tested stale `SIGKILL` state or fail closed on an active, legacy, unsafe, or
   inconsistent layout. Preserve a reported uncertain transaction for review.
   This recovery contract does not claim power-loss durability.
6. Add a regression test before changing retry, cleanup, authorization, or
   publication logic.

Security or privacy incidents follow `SECURITY.md`; do not paste credentials,
raw serials, content URIs, personal filenames, or pairing material into issues or
external-model prompts.

## 5. Release readiness / 发布判断

A distributable release requires all of the following, not merely a green CI run:

Run the read-only automated preflight first. It reports blockers without reading
or printing certificate subjects, credential values, or tokens:

```text
tools/check-release-readiness.sh --github
tools/check-release-readiness.sh --github --artifact /path/to/DroidMatch.app
```

`PASS` covers only the named automated boundary. `MANUAL` remains operator-owned,
and any `BLOCKED` result makes a release claim invalid.
An unreadable Git worktree state is `BLOCKED`, never equivalent to a clean tree.
The `--github` PASS specifically means HEAD equals the live GitHub `main` tip,
that exact commit has a green `push` run on branch `main`, the tip stayed stable
through the query sequence, the local HEAD and clean worktree stayed unchanged
through every slow check, and live protection still matches Phase A; a stale
green commit, PR/manual run, or merely having a protection object is insufficient.
An `--artifact` PASS additionally binds the App to that HEAD and requires a
clean release build, a valid deep/strict code seal, the reviewed sandbox bundle
boundary, and a valid notarization staple. Detailed signing/bundle-tool output
is intentionally suppressed because it may contain certificate subjects or
local paths.

- required device-matrix rows backed by redacted evidence;
- product pairing/reconnect/download/upload under the sandbox bundle;
- replacing the mount-verified local DMG's ad-hoc identity with Developer ID signing, notarization submission/stapling, and release checksum publication;
- bilingual current-status/release notes with no unsupported capability claims;
- clean full gates from the exact release commit.
- the Phase A GitHub governance baseline, so direct integration cannot bypass
  the exact-SHA checks required before `main` accepts the release commit.

Until those conditions hold, build only ad-hoc local artifacts and describe the
project as M1 validation software.

## 6. Handoff checklist / 交接清单

- Commit SHA and branch are explicit; worktree is clean or every local change is listed.
- Work completed in a disposable or secondary worktree is still unpublished
  until the intended branch is integrated and the canonical worktree is
  content-compared with the reviewed source. Name both the authoritative branch
  and canonical path in the handoff. / 在临时或次级工作树完成的改动仍属未发布；
  只有目标分支完成集成、规范工作树与已审查源完成内容比对后才可交接，并须明确
  写出权威分支与规范路径。
- Changed ownership boundaries and invariants are documented.
- Exact tests run, skipped device cases, and open risks are stated.
- Android Gradle runs with `--warning-mode fail`; assign any deprecation to
  project configuration or a pinned plugin before dependency upgrades land.
- The unsigned Android release APK is assembled and checked for the product
  launcher plus absence of the debug-only harness Activity.
- Its merged manifest is checked against the reviewed permission allowlist,
  non-debuggable/no-backup policy, and single exported product Activity.
- CI assembles both ordinary and sandboxed Mac Apps from the Swift release
  configuration; the bundle verifier freezes identity, executable, resource,
  dependency privacy-manifest, signature, embedded-adb, and entitlement boundaries.
- Offline packaging gates exercise App first-publication `RENAME_EXCL` and
  identity-checked replacement `RENAME_SWAP` recovery; DMG absence/replacement
  and rollback use EXCL/SWAP with two-way validation, previous/candidate/canonical
  dev/inode/size/SHA-256 binding, and concurrent insert/replace fail-closed tests.
  Protobuf generation likewise validates and synchronizes the exact generated
  tree, uses identity-checked EXCL/SWAP publication, recovers only a recorded
  pre/post mapping, and preserves concurrent outputs or unsafe transaction layouts;
  the offline gate covers each of those fail-closed paths.
  Record these only as process-kill/build evidence; they do not satisfy Developer
  ID, notarization, device, or power-loss requirements.
- Runtime dependency bumps must update `third_party/` attribution and the
  platform verifier: Mac ships only SwiftProtobuf notices, Android ships only
  protobuf-javalite notices, and build-only tools are not listed as runtimes.
- Android dependency verification defaults to strict. Regenerate SHA-256
  metadata with the complete gate task set, review every added component/hash,
  and retain the honest TOFU limitation unless publisher signatures are added.
  Platform-classified tools need one reviewed checksum per supported runner;
  the current `protoc` baseline covers macOS arm64 and Ubuntu x64.
- Resolve GitHub Action upgrades from the official repository, pin the peeled
  40-character commit (annotated tags have a separate tag-object SHA), and keep
  the human-readable version comment required by the M0 gate.
- GitHub push/CI state is linked.
- The next maintainer has one concrete next action and no hidden local-only setup.
