# Developer Onboarding

[中文版本](developer-onboarding-zh.md) · [Documentation index](README.md) ·
[Contributing](../CONTRIBUTING.md)

DroidMatch is an M1-stage macOS Android device-management product. The native
Mac App already performs serial-redacted discovery, visible pairing, paired
authentication, file/media browsing, structured diagnostics, and persistent
download/upload through the reusable Core and Presentation boundaries. The
Android App owns secure connection, trust, media permission, and SAF folder
authorization rather than a separate local file-manager experience.

It is not a public release yet. The open ADB M1 blockers are current-tip Slot A
release throughput and attended product USB insertion evidence on Slots A/C/D.
Developer ID signing, notarization, and release automation are deferred.

## Local quick start

### Prerequisites

- macOS 13 or newer
- Xcode and the Swift toolchain
- JDK 17
- Android SDK Platform 36, Build Tools 36.0.0, and platform-tools/ADB
- the checked-in Gradle wrapper and a network path for its declared dependencies

Clone the repository and check the toolchains:

```bash
git clone https://github.com/FoxBai/DroidMatch.git
cd DroidMatch
bash tools/check-env.sh --all
```

Build and test the Mac side:

```bash
bash tools/run-swift-tests.sh
tools/build-mac-app.sh
open mac/.build/app/DroidMatch.app
```

Build and test the Android side:

```bash
bash tools/run-android-gradle.sh \
  :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

This repository entry point validates and passes both the resolved JDK 17 and
Android SDK into Gradle. It does not depend on exports that a child
`check-env.sh` cannot preserve, and it needs no machine-local
`android/local.properties` commit.

These commands are local and do not imply permission to modify an attached
Android device.

## Read before changing code

Start with the smallest path that matches the task:

1. [M1 status](m1-status.md) for implemented behavior, blockers, and accepted evidence.
2. [Architecture](architecture.md) for ownership and dependency direction.
3. [Protocol](protocol.md), [protocol runtime](protocol-runtime.md),
   [path model](path-model.md), and [security model](security-model.md) for shared boundaries.
4. [Mac code overview](mac-code-overview.md) or
   [Android code overview](android-code-overview.md) for platform implementation.
5. [CI/CD](ci-cd.md) and the [M1 testing guide](m1-testing-guide.md) before
   changing gates or running on hardware.
6. [Maintainer runbook](maintainer-runbook.md) for handoff, incidents, and release decisions.

The complete map, including historical documents, is in the
[documentation index](README.md).

## Common tasks

### Run repository gates

Use the narrowest check while iterating, then the complete affected gate:

```bash
bash tools/check-m0.sh
python3 tools/check-source-size.py
bash tools/check-proto.sh
python3 tools/check-doc-links.py
bash tools/check-m1-run-logs.sh
bash tools/check-m1-skeleton.sh
```

### Regenerate protobuf

`proto/v1/*.proto` is the shared wire source of truth. Do not edit generated
Swift or Java sources manually.

```bash
bash tools/generate-swift-proto.sh
bash tools/run-android-gradle.sh :app:generateDebugProto
```

With `PROTOC_GEN_SWIFT` unset, Swift generation bootstraps the lockfile-pinned
toolchain. An explicit override must name a real executable.

### Inspect the harness without a device

```bash
swift run --package-path mac droidmatch-harness --help
tools/quick-test-scenarios.sh help
```

The scenario help is read-only. Running a scenario may install an APK, create
test data, modify permissions, and publish a result log.

## Physical-device safety

`adb devices -l` is a read-only visibility check. It does not authorize an
install, pairing attempt, transfer, permission change, or cleanup.

Before running a physical-device script:

1. Select the exact disposable or backed-up device and serial.
2. Record every expected device/Mac write and the cleanup plan.
3. Confirm whether the workflow requires attended approval or unplug/reconnect action.
4. Use the documented versioned runner profile.
5. Validate and redact the result before archiving it.

Follow the [M1 testing guide](m1-testing-guide.md) and
[device matrix](m1-device-matrix.md). A local pass, reused APK, dirty source,
or diagnostic-only fixture cannot satisfy a physical-device gate.

## Core concepts

### Dependency direction

Product UI depends on domain/session/transfer interfaces. Transport owns bytes
and connection state; RPC owns envelopes, IDs, and response matching; transfer
owns checkpoints, retry/resume, integrity, and atomic publication. Android
provider rules remain behind provider interfaces rather than in `RpcDispatcher`.

### Logical paths

DroidMatch never sends raw Android filesystem paths or `content://` URIs over
the wire. Examples include:

- `dm://roots/`
- `dm://app-sandbox/`
- `dm://media-images/`
- `dm://media-videos/`
- `dm://saf-<stable-id>/`

See the [path model](path-model.md) before adding or transforming a path.

### Milestones

- **M0:** closed specification baseline.
- **M1:** current product/transport/protocol validation milestone.
- **v1.0:** future distributable release; remaining M1 evidence and the deferred
  signing/notarization path must be resolved before making that claim.

AOA remains experimental and does not block completion of the current ADB M1 path.

## Development workflow

1. Write the change contract: goal, owned files, invariants, acceptance commands,
   non-goals, and stop conditions.
2. Read the owning current-state documents and tests.
3. Make the smallest reviewable change; keep generated code and unrelated files untouched.
4. Run narrow tests, then the complete affected gate.
5. Update current documentation in the same change.
6. Inspect the complete diff and report every changed file and skipped hardware/release work.
7. Follow the risk and integration rules in
   [GitHub governance](github-governance.md) and [CONTRIBUTING.md](../CONTRIBUTING.md).

Questions and ordinary bug reports belong in GitHub issues. Security reports
follow [SECURITY.md](../SECURITY.md) and must not include secrets, raw device
serials, private paths, or user files in a public issue.
