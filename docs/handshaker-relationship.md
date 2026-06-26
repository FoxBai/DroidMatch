# Relationship to HandShaker

## Position

DroidMatch is a new product, codebase, protocol, and visual identity. It is intended to replace the highest-value HandShaker workflows for modern macOS and Android users, but it is not a fork, clone, skin, or binary continuation of HandShaker.

The useful inheritance is workflow-level only:

- Connect an Android device from a Mac.
- Browse files and media.
- Move files reliably.
- Understand connection and permission failures.

The implementation inheritance is zero by default. DroidMatch must use its own source code, UI, protocol definitions, assets, signing identities, build pipeline, and distribution artifacts.

## Allowed References

The project may use HandShaker as a research reference in these limited ways:

- User-visible workflows and product expectations.
- Publicly observable behavior from running the old app on owned test devices.
- Compatibility notes about connection states, failure cases, and migration risks.
- Screenshots or notes used only for workflow analysis, not visual reproduction.
- Behavior-level protocol observations when needed to evaluate a timeboxed legacy adapter.

Any research output must be written as behavior-level notes or test results. It must not include copied source, decompiled snippets, asset files, binary patches, signing materials, or UI artwork.

## Forbidden Reuse

DroidMatch must not reuse:

- HandShaker or Smartisan brand names as the product identity.
- Old icons, images, colors, copy, UI layouts, animations, or other visual assets.
- Old macOS or Android binaries, embedded libraries, helper tools, or services.
- Source code, decompiled code, class structure, method bodies, or implementation-level recipes from the old product.
- Private signing keys, certificates, provisioning profiles, update feeds, analytics endpoints, or service credentials.

The name "HandShaker" may appear in engineering docs, migration notes, and compatibility research, but not as the DroidMatch product brand.

## Relationship to `handshaker-arm`

The separate repository at `/Users/baizhiming/Documents/handshaker-arm` is a research and maintenance reference only. Files from that repository must not be copied into DroidMatch unless they are independently created project notes with clear provenance and no old implementation content.

If that repository is inspected, the output should be limited to:

- Observed behavior.
- Test-device compatibility findings.
- Migration risks.
- Questions for the DroidMatch protocol or UX.

It should not become a dependency of DroidMatch.

## Legacy Compatibility Boundary

The default DroidMatch path is a new Mac client talking to a new DroidMatch Android service over the DroidMatch protocol.

Legacy HandShaker compatibility is optional and timeboxed. If explored, it must be isolated behind the same high-level boundaries as other transports:

- `DeviceDiscovery`
- `DeviceSession`
- `Transport`
- `RpcClient`
- Diagnostics reporting

Legacy compatibility must not introduce UI special cases, block the ADB/AOA DroidMatch path, or require shipping old binaries. If compatibility requires binary reuse or product-level cloning, the line is abandoned.

## Clean Research Rules

- Keep research notes separate from implementation files.
- Record whether a finding came from user-visible behavior, public documentation, device testing, or old-repo inspection.
- Describe behavior, states, timing, errors, and compatibility constraints; do not paste old code or decompiled structures.
- Implement DroidMatch behavior from the new protocol, module interfaces, and tests.
- Re-check this boundary before adding any legacy adapter code.

## M0 Exit Rule

M0 may treat HandShaker workflow replacement as in scope only after this boundary is accepted:

- Workflow compatibility is allowed.
- Brand, asset, code, binary, and UI reuse are out of scope.
- Legacy compatibility is a research line, not the v1.0 critical path.
