# Diagnostics

## Goal

When DroidMatch fails, the user and developer should know where it failed: USB, ADB, AOA, Android service, permission, protocol, transfer, or Mac UI.

## User-Facing Diagnostics

The Mac diagnostics panel should show:

- Connected device identity.
- Connection mode: ADB or AOA.
- ADB authorization state.
- ADB forward port.
- AOA permission and endpoint state.
- Android service state.
- Permission state.
- Recent errors.
- Recent state transitions.
- Current transfer throughput.
- Export support bundle button.

## Metrics

Track:

- USB insertion to device-visible time.
- Device-visible to handshake-complete time.
- First directory listing time.
- Thumbnail throughput.
- 100MB and 1GB transfer speed.
- Reconnect time.
- Error reason distribution.
- Mac and Android memory usage.

## Support Bundle

Support bundle should include:

- Redacted logs.
- Protocol version.
- Device model and Android version.
- macOS version.
- Connection mode as structured `TransportKind`.
- Transport state transitions.
- Recent error codes.
- Recent Android service state events.
- Transfer metrics.

Diagnostics event strings emitted by the M1 Android skeleton use this format:

```text
elapsed_realtime_nanos:thread:kind:code[:message]
```

The Android sender must redact sensitive paths, serial-like IDs, authorization headers, and token values before placing event strings on the wire.
