# Contributing / 参与贡献

DroidMatch is an M1-stage product implementation: the Mac has a native product
App and Android has a secure onboarding/trust surface, while signed distribution
and broader-matrix release evidence remain incomplete. Slot C product authentication
and transfer evidence is already archived. Start with
`README.md`, `docs/m1-status.md`, and `docs/technical-debt.md`; historical session
notes and fixtures are evidence, not the current source of truth.

DroidMatch 目前处于 M1 产品实现阶段：Mac 已有原生产品 App，Android 已有安全连接与信任管理入口；
Slot C 产品认证/传输已有归档真机证据，签名分发与更广设备矩阵的发布证据仍未完成。开始前请阅读上述三份当前事实文档。

## Change contract / 变更契约

Before implementation, write down the goal, owned files, invariants, acceptance
commands, non-goals, and stop conditions. One writer owns a file set at a time.
Keep protocol, security, transport, UI, tests, and live documentation aligned in
the same change. Do not let generated code, old logs, or a model response override
the schema, current source, tests, or physical evidence.

实现前先明确目标、文件所有权、不变量、验收命令、非目标与停止条件。同一组文件同一时间只允许一个写入者。

For model-assisted work, follow `AGENTS.md`: MiMo is the default economical
implementation/review model, GLM is reserved for difficult cross-module work,
DeepSeek Flash suits bounded mechanical checks, and GPT owns architecture,
security, product judgment, and final integration. A model never approves its
own patch; repository tests and device evidence outrank model confidence.

## Required verification / 必需验证

Run the narrowest checks while iterating, then the complete affected gate:

```text
bash tools/check-env.sh --all
bash tools/check-m0.sh
python3 tools/check-source-size.py
python3 tools/check-doc-links.py
bash tools/check-m1-skeleton.sh
```

Mac-only changes must run `bash tools/run-swift-tests.sh` and build the product
App with `tools/build-mac-app.sh`. Android changes must use the checked-in wrapper:

```text
cd android
./gradlew --no-daemon :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:lintDebug
```

Physical-device work is never implied by an attached device. Record the exact
serial, obtain explicit disposable-device authorization, list writes and cleanup,
and archive only redacted evidence. `adb devices -l` alone is read-only.

真机在线不代表获准写入；安装、配对、传输、授权变更与撤销都必须先获得明确授权并定义清理步骤。

## Pull-request handoff / PR 交接

Use the repository PR template. State the behavior change, ownership boundaries,
tests actually run, skipped device/signing work, documentation updates, and open
risks. A green CI run is not evidence of notarization or physical-device behavior.
Security reports follow `SECURITY.md`, not public issues.

Contributions are licensed under MPL-2.0 unless a file explicitly states otherwise.
Do not reuse HandShaker code, assets, binaries, signing material, branding, or UI.
