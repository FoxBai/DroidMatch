# Developer Onboarding Guide

Welcome to DroidMatch! This guide will help you get started with the codebase quickly.

## What is DroidMatch?

DroidMatch is a modern Android device management client for macOS, designed as a HandShaker replacement. It's native to Apple Silicon, focuses on stability and speed, and is built with diagnostics and local-first principles in mind.

**Current Status:** M1 harness phase (connection and file transfer validation)

## Quick Start (5 minutes)

### Prerequisites
- macOS 13+ (for Mac development)
- Xcode command-line tools
- Android SDK with ADB
- Java 17+ (for Android development)

### Clone and Verify
```bash
git clone <repository-url>
cd DroidMatch

# Verify M0 specs and protobuf compilation
bash tools/check-m0.sh
bash tools/check-proto.sh

# Build Mac harness
swift build --package-path mac

# Build Android APK
cd android && ./gradlew :app:assembleDebug
```

### Run Your First Test
```bash
# Connect an Android device via USB
adb devices -l

# Quick smoke test (if device is connected)
tools/quick-test-scenarios.sh basic-smoke --serial <your-serial>
```

## Essential Reading (30 minutes)

Read these documents in order:

1. **[README.md](../README.md)** - Project overview and current status
2. **[docs/m0-closeout.md](m0-closeout.md)** - Specification decisions
3. **[docs/m1-status.md](m1-status.md)** - Current implementation status
4. **[docs/protocol.md](protocol.md)** - Wire protocol overview
5. Choose your platform:
   - Mac: **[docs/mac-code-overview.md](mac-code-overview.md)**
   - Android: **[docs/android-code-overview.md](android-code-overview.md)**

## Documentation Map

### Getting Started
- **[README.md](../README.md)** - Start here
- **[CONTRIBUTING.md](../CONTRIBUTING.md)** - How to contribute
- **[SECURITY.md](../SECURITY.md)** - Security policy
- **This file** - Onboarding guide

### Architecture & Design
- **[docs/architecture.md](architecture.md)** - System architecture
- **[docs/product-scope.md](product-scope.md)** - What's in/out of scope
- **[docs/feature-matrix.md](feature-matrix.md)** - Feature comparison
- **[docs/handshaker-relationship.md](handshaker-relationship.md)** - Relationship to HandShaker
- **[docs/security-model.md](security-model.md)** - Security boundaries

### Protocol & Implementation
- **[docs/protocol.md](protocol.md)** - Wire protocol schemas
- **[docs/protocol-runtime.md](protocol-runtime.md)** - Runtime limits and scheduling
- **[docs/path-model.md](path-model.md)** - Logical path abstraction
- **[docs/android-permissions.md](android-permissions.md)** - Android permission model

### Code Overview
- **[docs/mac-code-overview.md](mac-code-overview.md)** - Mac codebase guide
- **[docs/android-code-overview.md](android-code-overview.md)** - Android codebase guide
- **[mac/README.md](../mac/README.md)** - Mac build instructions
- **[android/README.md](../android/README.md)** - Android build instructions

### Testing & Status
- **[docs/m1-status.md](m1-status.md)** - Current M1 status summary
- **[docs/m1-testing-guide.md](m1-testing-guide.md)** - Step-by-step test instructions
- **[docs/m1-device-matrix.md](m1-device-matrix.md)** - Required devices and criteria
- **[fixtures/m1-runs/README.md](../fixtures/m1-runs/README.md)** - Test result guidelines

### M0 Historical
- **[docs/m0-closeout.md](m0-closeout.md)** - M0 decisions
- **[docs/m0-checklist.md](m0-checklist.md)** - M0 requirements
- **[docs/decision-log.md](decision-log.md)** - Key decisions

## Common Tasks

### Building

**Mac:**
```bash
swift build --package-path mac
bash tools/run-swift-tests.sh
```

**Android:**
```bash
cd android
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
./gradlew :app:lintDebug
```

### Testing

**Quick test scenarios:**
```bash
# See all scenarios
tools/quick-test-scenarios.sh help

# Basic smoke test
tools/quick-test-scenarios.sh basic-smoke --serial <serial>

# Download throughput test
tools/quick-test-scenarios.sh download-100mb-throughput --serial <serial>

# Full M1 matrix (~10 minutes)
tools/quick-test-scenarios.sh full-matrix --serial <serial>
```

**Manual harness commands:**
```bash
# List devices
swift run --package-path mac droidmatch-harness devices

# Create ADB forward
swift run --package-path mac droidmatch-harness forward \
  --serial <serial> --remote-port 39001

# M1 smoke test
swift run --package-path mac droidmatch-harness m1-smoke \
  --port <local-port>
```

### Regenerating Protobuf

**Mac:**
```bash
brew install protobuf
bash tools/generate-swift-proto.sh
```

**Android:**
```bash
cd android
./gradlew :app:generateDebugProto
```

### Running CI Checks Locally
```bash
bash tools/check-m0.sh
bash tools/check-proto.sh
bash tools/check-m1-skeleton.sh
```

## Key Concepts

### DroidMatch Logical Paths
DroidMatch uses logical paths instead of raw Android filesystem paths:
- `dm://roots/` - Virtual root listing
- `dm://media-images/` - MediaStore images
- `dm://media-videos/` - MediaStore videos
- `dm://app-sandbox/` - App private files
- `dm://saf-<stable-id>/` - User-selected SAF directory

See [docs/path-model.md](path-model.md) for details.

### Protocol Stack
1. **Transport:** TCP over ADB forward or AOA
2. **Framing:** Length-prefixed (uint32_be + payload, max 4 MiB)
3. **RPC:** Protobuf `RpcEnvelope` with request/response/error
4. **Transfer:** Receiver-paced chunks with CRC32 validation

See [docs/protocol.md](protocol.md) for details.

### M1 Scope
M1 validates the harness before product UI work starts. It includes:
- ✅ Handshake and heartbeat
- ✅ Device info and diagnostics
- ✅ Directory listing (media, SAF, app-sandbox)
- ✅ Single-stream download/upload
- ✅ M1 dual-download multiplexing probe (two active streams plus control-plane heartbeat)
- ✅ Transfer resume with fingerprint validation
- ✅ Transfer cancel and pause
- ✅ Configurable in-process transport-loss retry queue (legacy default: one retry)
- ✅ Local product-async mixed multiplexing with one reader, atomic download file receive, preflighted upload windows, protocol cancellation, and heartbeat routing
- ✅ Product download/upload sidecar recovery coordinators and observable in-process scheduler
- ✅ MainActor native transfer presentation binding with privacy-bounded row items and scheduler-authoritative actions
- ✅ Dual/mixed probes are both device-script invocable
- ⚠️ Archived physical dual/mixed evidence
- ✅ Opt-in Core persistent queue reconstruction with write-ahead executor admission and sidecar-gated recovery
- ⚠️ Future app lifecycle, storage URL, sandbox file-access, and `interrupted` recovery UX integration
- ⚠️ Visual macOS app target and transfer queue screen

See [docs/m1-status.md](m1-status.md) for detailed checklist.

## Project Structure

```
DroidMatch/
├── android/          # Android app (foreground service, RPC dispatcher, providers)
├── mac/              # Mac harness (ADB client, framed TCP, M1 smoke client)
├── proto/            # Protobuf schemas (v1/rpc.proto, transfer.proto, etc.)
├── docs/             # Documentation (architecture, protocol, testing)
├── tools/            # Scripts (check-m0.sh, run-m1-device-smoke.sh, etc.)
├── fixtures/         # Test data and result logs
└── .github/          # CI workflows
```

## Development Workflow

1. **Pick a task** from [docs/m1-status.md](m1-status.md) "Next Steps"
2. **Read relevant docs** (protocol, code overview, architecture)
3. **Make changes** (Mac and/or Android)
4. **Test locally:**
   - Run unit tests
   - Run harness commands manually
   - Use `quick-test-scenarios.sh` for integration tests
5. **Update documentation:**
   - Update README if project state changed
   - Update `docs/m1-status.md` if feature completed
   - Add test logs to `fixtures/m1-runs/` if relevant
6. **Run CI checks:** `bash tools/check-m1-skeleton.sh`
7. **Commit and push** (see [CONTRIBUTING.md](../CONTRIBUTING.md))

## FAQ

**Q: Where do I start if I want to add a new RPC request?**
A: See "Adding a New RPC Request" sections in [docs/mac-code-overview.md](mac-code-overview.md) and [docs/android-code-overview.md](android-code-overview.md).

**Q: How do I run tests on a real device?**
A: See [docs/m1-testing-guide.md](m1-testing-guide.md) for step-by-step instructions.

**Q: What's the difference between M0, M1, and v1.0?**
A:
- **M0:** Specification phase (complete)
- **M1:** Harness validation phase (current)
- **v1.0:** First product release (future, requires product UI)

**Q: Why is there no product UI yet?**
A: M1 validates the protocol and transfer reliability before UI work starts. This ensures the foundation is solid.

**Q: Can I help with testing?**
A: Yes! We need tests on API 26-29 (Slot A) and API 33-35 (Slot C) devices. See [docs/m1-device-matrix.md](m1-device-matrix.md).

**Q: What's the AOA path status?**
A: AOA (Android Open Accessory) is experimental and blocked until ADB path completes M1 validation on 3 devices.

## Communication

- **Issues:** File bugs, feature requests, or questions as GitHub issues
- **Pull Requests:** See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines
- **Security:** See [SECURITY.md](../SECURITY.md) for reporting vulnerabilities

## Next Steps

After completing this onboarding:

1. **Choose your platform:** Mac or Android
2. **Read the code overview:** [mac-code-overview.md](mac-code-overview.md) or [android-code-overview.md](android-code-overview.md)
3. **Browse the code:** Start with the files mentioned in the overview
4. **Run the tests:** Connect a device and try `quick-test-scenarios.sh`
5. **Pick a task:** Check [docs/m1-status.md](m1-status.md) for pending work
6. **Ask questions:** File an issue if anything is unclear

Welcome to the team! 🚀
