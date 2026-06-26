# Decision Log

## 2026-06-26

| Decision | Rationale |
|---|---|
| Project name is DroidMatch | Establish a new identity independent from HandShaker and Smartisan. |
| Build a modern replacement, not a clone | Preserve valuable workflows while avoiding old brand, UI assets, and binary implementation. |
| Use a new monorepo at `/Users/baizhiming/Documents/DroidMatch` | Keep the new product separate from the existing binary-maintenance repository. |
| Main route is Mac + Android dual-end rewrite | Control protocol, permissions, diagnostics, transfer recovery, and AOA/ADB behavior. |
| ADB is the stable v1 path | It is the fastest reliable route for M1 and early v1.0. |
| AOA is a PoC-gated consumer path | It can reduce USB debugging friction, but it does not solve Android permissions by itself. |
| Old HandShaker Android compatibility is a timeboxed research line | It may reduce migration cost, but must not block the new product architecture. |
| Protobuf is the protocol schema; gRPC is not mandatory | AOA bulk transport benefits from lightweight framing. |
| v1.0 scope is intentionally narrow | Connection, files, basic media, transfer recovery, diagnostics, and distribution come first. |

