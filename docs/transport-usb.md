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
- Android declares `android.hardware.usb.accessory` as optional, because ADB remains the M1/v1.0 baseline and AOA support must not narrow install compatibility.

## M1 Acceptance

- USB insertion to visible device: <= 5 seconds.
- Measure this from the monotonic timestamp taken immediately before the attended
  `INSERT NOW` signal to exactly one foreground discovery card whose stable
  Accessibility identifier is `app.droidmatch.discovery-device-card` and whose
  structured label contains the exact model component plus the exact `ADB`
  component. Trusted-device history, partial model substrings, duplicate matching
  cards, and file names do not count. ADB visibility alone is not product evidence.
  The formal runner also pins clean current-main and the exact verified running
  release App bundle, requires post-run physical-action attestation, and validates
  the staged fixture without reading a device serial.
- Handshake success across 20 attempts: >= 95%.
- First directory screen: <= 1 second.
- 100MB download:
  - ADB target: >= 20 MiB/s on the same three selected required devices (one Slot A, one Slot C, and one Slot D or E).
  - AOA target: >= 30 MB/s.
- 100MB ADB upload: >= 20 MiB/s on that same selected three-device set.
- ADB throughput evidence must come from the release-configured Mac harness;
  debug/Onone measurements are diagnostic only.
- Cable unplug/replug recovery: <= 3 seconds or a clear failure reason.
- Resume download from interrupted offset.

## User-Facing Failure Reasons

The Mac app should map low-level transport and protocol failures to these stable user-facing reasons:

- No USB device detected.
- Device is visible but not authorized for ADB.
- USB debugging is disabled or unavailable.
- ADB device is offline.
- ADB forward port could not be allocated.
- Android DroidMatch service is not installed.
- Android DroidMatch service is installed but not reachable.
- Protocol version is unsupported.
- Requested capability is not available on this device or build.
- AOA accessory permission was denied.
- AOA endpoint could not be opened.
- Cable or USB connection was lost.
- Transfer was interrupted and can be resumed.
- Transfer failed integrity validation.
- Android permission is required.
- Destination path is read-only.
