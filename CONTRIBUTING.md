# Contributing

DroidMatch is in the M1 harness phase. Keep changes small, verifiable, and aligned with the current placeholder boundaries in `README.md`, `mac/README.md`, and `android/README.md`.

Before opening or merging a change, run the relevant gates:

```text
bash tools/check-m0.sh
bash tools/check-proto.sh
bash tools/check-m1-skeleton.sh
```

Mac-only changes should also run:

```text
swift test --package-path mac
```

Android APK changes should run with Gradle 8.13 available:

```text
gradle --no-daemon -p android :app:assembleDebug
```

When changing protocol, security, transport, Android service behavior, or Mac harness behavior, update the matching docs in the same change. Do not reuse HandShaker code, assets, binaries, signing material, branding, or copied UI implementation.
