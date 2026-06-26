# DroidMatch

DroidMatch is a modern Android device management client for macOS.

The project goal is to build an Apple Silicon native, stable, fast, diagnosable replacement for the classic HandShaker workflow. DroidMatch should preserve the useful user journeys, not the old brand, visual assets, binary implementation, or legacy UI.

## Direction

- Local-first, USB-first, zero-cloud by default.
- Mac + Android dual-end rewrite.
- ADB is the stable compatibility path.
- AOA is the low-friction consumer path and must be proven by PoC data.
- v1.0 focuses on connection, files, basic media browsing, transfer recovery, diagnostics, signing, and distribution.
- Screen mirroring, notification mirroring, clipboard sync, folder subscription, and Wi-Fi are v1.5+ candidates.

## Repository Layout

```text
DroidMatch/
├── android/
├── mac/
├── proto/
├── docs/
├── tools/
├── fixtures/
└── .github/workflows/
```

## M0 Goal

M0 is the specification phase. It ends when the team can answer:

- What does DroidMatch v1.0 do and not do?
- What are the Mac, Android, protocol, and transport module boundaries?
- How do ADB and AOA discover, handshake, reconnect, and fail?
- How does the protocol version, cancel requests, and transfer large files?
- How does Android permission degradation work?
- How will M1 be verified on real devices?

Start with [docs/m0-checklist.md](docs/m0-checklist.md).

