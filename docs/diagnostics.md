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
- Connection mode.
- Transport state transitions.
- Recent error codes.
- Transfer metrics.

