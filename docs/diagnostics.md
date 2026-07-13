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

Current Core status: `AsyncTransferScheduler` exposes monotonic receiver-confirmed
bytes/total plus `recentBytesPerSecond`. The rate uses a two-second, time-weighted
window over confirmed checkpoints and a monotonic uptime clock. A retry clears the
window, a confirmation gap longer than two seconds starts a fresh baseline, and
duplicate offsets cannot manufacture throughput. A running job automatically
broadcasts a nil rate after two seconds without a new confirmation; a terminal
transition freezes any sample that is still valid at that boundary. This local
diagnostic does not mean the protocol `TransferProgress` event is enabled.

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

Android error events use only the stable operation code and exception class;
they contain no `Throwable` message, path, serial-like ID, authorization header,
or token value. Other event fields remain bounded before they are placed on the
wire.
