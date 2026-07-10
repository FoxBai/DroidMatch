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

## 4. Incident triage / 故障处理

1. Stop new writes and preserve the first failing command/output.
2. Classify the boundary: environment, ADB, frame, handshake/auth, provider,
   checkpoint/recovery, presentation, or packaging.
3. Reproduce with the narrowest deterministic local test before a device rerun.
4. For transfer incidents, preserve sidecar/partial metadata without exposing
   user paths or contents; never silently restart a mismatched resume.
5. Add a regression test before changing retry, cleanup, or authorization logic.

Security or privacy incidents follow `SECURITY.md`; do not paste credentials,
raw serials, content URIs, personal filenames, or pairing material into issues or
external-model prompts.

## 5. Release readiness / 发布判断

A distributable release requires all of the following, not merely a green CI run:

- required device-matrix rows backed by redacted evidence;
- product pairing/reconnect/download/upload under the sandbox bundle;
- Developer ID signing, notarization, DMG packaging, and checksum verification;
- bilingual current-status/release notes with no unsupported capability claims;
- clean full gates from the exact release commit.

Until those conditions hold, build only ad-hoc local artifacts and describe the
project as M1 validation software.

## 6. Handoff checklist / 交接清单

- Commit SHA and branch are explicit; worktree is clean or every local change is listed.
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
- Runtime dependency bumps must update `third_party/` attribution and the
  platform verifier: Mac ships only SwiftProtobuf notices, Android ships only
  protobuf-javalite notices, and build-only tools are not listed as runtimes.
- GitHub push/CI state is linked.
- The next maintainer has one concrete next action and no hidden local-only setup.
