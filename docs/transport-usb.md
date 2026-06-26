# USB Transport

## Goals

- ADB path must be reliable enough for v1.0 production use.
- AOA path must be proven before becoming the default user path.
- Both paths must expose the same high-level `Transport` interface.

## ADB Path

States:

```text
NotConnected
DeviceVisible
Unauthorized
Authorized
Forwarding
ServiceReachable
Handshaking
Ready
SoftDisconnected
Reconnecting
Failed
```

Rules:

- Reuse the user's adb-server when possible.
- Do not kill adb-server as a routine recovery step.
- Allocate forward ports dynamically.
- Detect port conflicts and retry with a new port.
- Listen for device changes.
- Surface authorization failures clearly.

## AOA Path

States:

```text
NotConnected
AccessoryCandidate
PermissionRequested
PermissionGranted
EndpointOpen
Handshaking
Ready
SoftDisconnected
Reconnecting
Failed
```

Rules:

- Treat AOA as a transport channel only.
- Do not assume file/media permissions are granted.
- Measure per-device stability.
- Keep AOA behind a feature flag until M1 gates pass.

## M1 Acceptance

- USB insertion to visible device: <= 5 seconds.
- Handshake success across 20 attempts: >= 95%.
- First directory screen: <= 1 second.
- 100MB download:
  - ADB target: >= 20 MB/s.
  - AOA target: >= 30 MB/s.
- Cable unplug/replug recovery: <= 3 seconds or a clear failure reason.
- Resume download from interrupted offset.

