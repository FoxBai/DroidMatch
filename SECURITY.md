# Security Policy

DroidMatch is local-first and USB-first, but local USB and ADB access are still trust boundaries. Please report security issues privately rather than opening a public issue.

Current security-sensitive areas:

- ADB forward localhost exposure and session authentication.
- Android file and media permission handling.
- Diagnostics redaction for device serials, user paths, tokens, secrets, and support bundles.
- Protocol parsing, oversized frames, malformed protobuf payloads, and transfer resume validation.

Until a public reporting channel is chosen, send security findings directly to the project owner. Include the affected commit, reproduction steps, expected impact, and whether logs or support bundles contain private data.

Do not attach raw personal files, unredacted device serial numbers, access tokens, signing material, private endpoints, or copied third-party proprietary code.
