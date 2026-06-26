# M1 Real-Device Matrix

M1 validates the connection and file-transfer harness before product UI work starts. The matrix is intentionally small but must cover Android storage generations, vendor USB behavior, and both transport paths.

## Required Devices

| Slot | Android Range | Device Class | Required Transport | Purpose |
|---|---|---|---|---|
| A | API 26-29, Android 8-10 | Legacy storage-era phone | ADB | Verify SAF/MediaStore-first behavior on the minimum supported generation. |
| B | API 30-32, Android 11-12L | Scoped-storage transition phone | ADB | Verify Android 11+ storage degradation and permission changes. |
| C | API 33-35, Android 13-15 | Recent mainstream phone | ADB and AOA candidate | Verify current permission prompts, media access, and AOA viability. |
| D | API 30+ | Non-Google domestic OEM phone | ADB | Verify vendor USB authorization, background service behavior, and package visibility differences. |
| E | API 30+ | Tablet or large-storage device | ADB | Verify large directory listings and 1GB transfer behavior. |

At least three physical devices must be available before M1 starts: one from slot A, one from slot C, and one domestic OEM or tablet device from slot D or E. AOA cannot be promoted beyond experimental unless at least two physical devices pass the AOA checks.

## M1 Harness Checks

Each required device should run:

- USB insertion to visible device time.
- ADB authorization and reconnect.
- DroidMatch service reachability.
- `ClientHello` / `ServerHello` handshake.
- `DeviceInfoRequest`.
- `ListDirRequest` on a public media root and a user-selected SAF root.
- 100MB download using `OpenTransfer` and `TransferChunk`.
- 100MB upload using `OpenTransfer` and `TransferChunk`.
- Cable unplug/replug during transfer.
- Resume from interrupted offset.
- `CancelTransferRequest` and `PauseTransferRequest`.
- Diagnostics export with recent state transitions and errors.

AOA-capable devices additionally run:

- Accessory permission grant and denial.
- Endpoint open and teardown.
- Handshake over AOA.
- 100MB transfer throughput.
- Cable unplug/replug recovery.

## Pass Criteria

M1 passes only when:

- ADB handshake succeeds in at least 19 of 20 attempts on each required device.
- USB insertion to visible device is <= 5 seconds on each required device.
- First directory listing is <= 1 second on warm service for public media roots.
- 100MB ADB download is >= 20 MB/s on at least three required devices.
- Interrupted download resumes from the accepted offset without data corruption.
- Permission-denied, read-only, unauthorized, and transport-lost cases map to stable user-facing failure reasons.
- Diagnostics identify whether failure came from USB, ADB, AOA, Android service, permission, protocol, transfer, or Mac harness.

AOA passes its M1 gate only when:

- AOA handshake succeeds in at least 19 of 20 attempts on at least two devices.
- 100MB AOA download is >= 30 MB/s on at least two devices.
- Cable unplug/replug recovers within 3 seconds or reports a clear failure reason.

## Result Log Template

Record each run in `fixtures/m1-runs/` once harnesses exist.

```text
date:
device slot:
manufacturer/model:
android version/api:
build channel:
transport:
handshake attempts:
visible time:
first list time:
100MB download:
100MB upload:
resume result:
permission cases:
diagnostics bundle:
notes:
```
