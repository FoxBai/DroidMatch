# DroidMatch Documentation / 文档索引

This page explains where to start, which documents describe current behavior,
and which files are historical evidence. It is the navigation layer; protocol,
security, and product truth remain in their owning documents.

本页说明从哪里开始、哪些文档描述当前行为、哪些文件只属于历史证据。它只负责导航；
协议、安全和产品事实仍由各自的责任文档维护。

## Start here / 从这里开始

| Audience / 读者 | Reading path / 阅读顺序 |
|---|---|
| Product visitor / 项目访客 | [Project README](../README.md) → [M1 status](m1-status.md) |
| New contributor / 新贡献者 | [Developer onboarding](developer-onboarding.md) · [中文](developer-onboarding-zh.md) → [Contributing](../CONTRIBUTING.md) |
| Mac developer / Mac 开发者 | [Architecture](architecture.md) → [Mac README](../mac/README.md) → [Mac code overview](mac-code-overview.md) |
| Android developer / Android 开发者 | [Architecture](architecture.md) → [Android README](../android/README.md) → [Android code overview](android-code-overview.md) |
| Protocol or security work / 协议或安全工作 | [Protocol](protocol.md) → [Runtime](protocol-runtime.md) → [Path model](path-model.md) → [Security model](security-model.md) |
| Maintainer / 维护者 | [M1 status](m1-status.md) → [Technical debt](technical-debt.md) → [Maintainer runbook](maintainer-runbook.md) |

## Current truth / 当前事实

These documents describe the current repository or product contract and must be
updated with the behavior they own:

以下文档描述当前仓库或产品契约；其所负责的行为变化时必须同步更新：

| Topic / 主题 | Owner document / 责任文档 |
|---|---|
| Implemented behavior, blockers, and accepted evidence / 已实现行为、阻塞项和有效证据 | [M1 status](m1-status.md) · [中文](m1-status-zh.md) |
| Application metadata and sharing / 应用信息与共享 | [Application library](application-library.md) |
| System ownership and dependency direction / 系统职责和依赖方向 | [Architecture](architecture.md) |
| Wire schema and runtime semantics / Wire schema 与运行时语义 | [Protocol](protocol.md) · [Protocol runtime](protocol-runtime.md) · `proto/v1/*.proto` |
| Logical paths and provider mapping / 逻辑路径与 provider 映射 | [Path model](path-model.md) |
| Trust, authentication, privacy, and permissions / 信任、认证、隐私与权限 | [Security model](security-model.md) · [Pairing design](pairing-auth-design.md) · [Android permissions](android-permissions.md) |
| Local and hosted checks / 本地与托管门禁 | [CI/CD](ci-cd.md) |
| Physical-device procedure and evidence admission / 真机步骤与证据准入 | [M1 testing guide](m1-testing-guide.md) · [中文](m1-testing-guide-zh.md) · [Device matrix](m1-device-matrix.md) |
| Maintainer operations and repository governance / 维护操作与仓库治理 | [Maintainer runbook](maintainer-runbook.md) · [GitHub governance](github-governance.md) |

`docs/m1-status.md` is the first place to check a current capability or blocker.
Source code and tests decide implementation behavior; versioned, validated
physical-device records decide physical evidence. A prose summary cannot promote
a local test or diagnostic fixture into device evidence.

判断当前能力或阻塞项时，先查 `docs/m1-status.md`。源码和测试决定实现行为；经过版本化
校验的真机记录决定真机证据。文字总结不能把本地测试或诊断 fixture 升格为真机证据。

## Reference and design / 参考与设计

- [Product scope](product-scope.md) and [feature matrix](feature-matrix.md) describe
  intended release scope; they do not override current M1 status.
- [Mac code overview](mac-code-overview.md) and
  [Android code overview](android-code-overview.md) orient contributors to the
  current implementation.
- [Diagnostics](diagnostics.md), [USB transport](transport-usb.md), and
  [HandShaker relationship](handshaker-relationship.md) define focused boundaries.
- [Decision log](decision-log.md) records why important choices were made.
- [Technical debt](technical-debt.md) tracks structural risks and their evidence;
  completed work described there is history, not a new product capability claim.

中文：产品范围和功能矩阵描述目标版本，不覆盖当前 M1 状态；代码导览用于定位实现；
decision log 与 technical debt 记录原因和结构风险，也不能代替当前产品事实。

## Historical evidence / 历史证据

The following material is intentionally retained but is not a source of current
product truth:

以下内容会保留，但不是当前产品事实源：

- `fixtures/m1-runs/`: redacted, versioned device-run evidence governed by its
  profile and validator.
- `fixtures/android-layout/` and `fixtures/product-usb-insertion/`: specialized
  evidence tracks with their own admission rules.
- [Session summary 2026-07-05](session-2026-07-05.md): a snapshot of one work
  session; later status and source take precedence.
- [M0 checklist](m0-checklist.md) and [M0 closeout](m0-closeout.md): closed
  milestone decisions retained for provenance.

Never edit byte-frozen legacy fixtures or recompute their manifest to bless
drift. New evidence must be produced by the documented runner profile.

不得修改 byte-frozen 历史 fixture，也不得通过重算 manifest 接受漂移；新证据必须由
文档规定的 runner profile 生成。

## Language and maintenance / 语言与维护

- The root README is Chinese-first and links to the English developer guide.
- Paired English/Chinese M1 status, testing, and onboarding documents form one
  maintenance contract. A behavior or procedure added to one must be reflected
  in the paired document in the same change.
- Many low-level engineering references are English-first. Operator-facing
  warnings and repository workflows retain paired wording where practical.
- Keep navigation concise. Put implementation detail in the document that owns
  the invariant instead of appending it to the root README.
- Wrap prose for reviewability, use descriptive link text, and run the document
  checks before handoff.

中文：根 README 以中文为主；成对的中英文状态、测试和入门文档属于同一维护契约，不能
单边更新。低层参考文档可保持英文优先，但面向操作者的警告和工作流应尽量保留双语。

```bash
python3 tools/check-doc-links.py
python3 tools/check-live-doc-truth.py
python3 tools/check-maintainer-contract.py
```
