# September M1 Integration / 九月 M1 集成

This change integrates PRs #132–#150 against the reviewed `69453dd` main baseline.
It preserves the original focused fixes and resolves their combined lifecycle,
subprocess-environment, and documentation conflicts. The resulting software stays
an internal M1 validation build. / 本次整合已有 19 项修复，解决组合后的生命周期、
进程环境与文档冲突；产物仍属于内部 M1 验证版本。

## Contract / 工作合同

- Goal: land the accumulated M1 repairs on canonical `main` and produce local
  release-configuration artifacts. / 目标：把积累的 M1 修复合入规范 `main` 并产出本地构建。
- Allowed files: the inventory below; one writer owns the canonical checkout.
- Risk: R2, Phase A; the owner authorized main synchronization on 2026-09-05.
  Self-review and automated adversarial review are supporting evidence, not
  independent human approval. External human review remains required before
  public beta or stable release.
- Invariants: loopback endpoints, paired proof, current permissions, opaque action
  identities, drain-before-revocation, exact live upload cancellation, immutable
  archived device evidence, and fail-closed publication/uncertainty remain intact.
- Acceptance: focused integration regressions, the full M0 and M1 skeleton gates,
  protected PR candidate checks, exact-main push checks, and a clean canonical
  checkout matching the reviewed candidate tree. Exact run results belong in the
  integration PR and handoff; this contract does not substitute for passing CI.
- Non-goals: wire schema changes, new dependencies, AOA, physical-device writes,
  Developer ID signing, notarization, and release automation.
- Stop conditions: retain unrelated changes and ambiguous cleanup state; never
  bypass failed checks or force remote history. Request attended hardware action
  only for the remaining physical criteria.

## Integration decisions / 集成决策

- Android endpoint failure retires the registered service before notification
  removal and stop. Teardown preserves retryable `FAILED`; callbacks require the
  same owner and a non-retired, non-draining instance. Credential deletion still
  waits for admitted RPC workers. / Android 失败停服先退役当前 owner；保留可重试失败，
  旧回调不能复活端点；删除凭据仍等待已准入请求退出。
- The `posix_spawn` runner receives the exact optional environment: `nil` inherits,
  while an explicit empty map passes no variables. Existing process-group, pipe,
  timeout, and owned-forward cleanup behavior is retained. / 进程环境准确传递，
  显式空环境不回退到宿主变量，进程与 forward 清理边界保持。
- Browser search, mutation confirmation, and preview use the final shared-window
  contexts already reviewed in #145. MediaStore cancellation uses #149's final
  post-ACK source-validation fix. / 浏览器采用最终共享窗口上下文；媒体上传取消保留
  最终 ACK 后的源身份复核，不把源变化误报为清理未知。
- Three focused integration regressions cover exact/empty child environments and
  callbacks from replaced or retired service owners. Tests assert only bounded
  values so an environment-isolation failure cannot print inherited secrets.
- The existing descriptor-inheritance regression now checks bytes on its original
  sentinel pipe. A shell may reuse a closed descriptor number for redirection;
  successful writing to that number alone did not prove a leaked descriptor.

## Remaining acceptance / 剩余验收

Slot A current-main release throughput and attended product USB insertion on
Slots A/C/D remain open. No physical-device fixture is added by this integration.
Developer ID signing, notarization, and release automation remain deferred.

Slot A 当前 main 的 release 吞吐，以及 Slot A/C/D 的人工 USB 插入时延仍待验收。
本次不新增真机证据；正式签名、公证与发布自动化继续暂缓。

## Source candidates / 来源候选

| PR | Reviewed branch head | Change |
|---|---|---|
| [#132](https://github.com/FoxBai/DroidMatch/pull/132) | `430b0fb9ef0fbcdcf435d5bfdddcf9081054ec1b` | Harden Mac icon renderer failures |
| [#133](https://github.com/FoxBai/DroidMatch/pull/133) | `a5a4042412a51d9513f4e85b2ac65e44130ae6ff` | Restore Python 3.9 maintainer gate compatibility |
| [#134](https://github.com/FoxBai/DroidMatch/pull/134) | `67ffecca32bd14d683a86b9652e99ef817ef7f00` | Restore Darwin hook cleanup proof |
| [#135](https://github.com/FoxBai/DroidMatch/pull/135) | `8a51f76a5d800605eebc1bf25818a238b251b9e6` | Recover diagnostics from loader cancellation |
| [#136](https://github.com/FoxBai/DroidMatch/pull/136) | `565428749846c69d58319022740028b39c470957` | Bound ProcessRunner descendant cleanup |
| [#137](https://github.com/FoxBai/DroidMatch/pull/137) | `76465295c2ef7636b22abbe82f76226aa93d7898` | Keep SAF picker launch failures recoverable |
| [#138](https://github.com/FoxBai/DroidMatch/pull/138) | `281a6b6eb877fb218264129fdde92c74d86f574b` | Stabilize concurrent Swift proto generation test |
| [#139](https://github.com/FoxBai/DroidMatch/pull/139) | `0bec2e7bd96095d372169e3d7b5fc7e35dd96c57` | Fix Android endpoint foreground-service lifecycle |
| [#140](https://github.com/FoxBai/DroidMatch/pull/140) | `e9360b56ac6dd23696e1c0035cd627bfecd8b723` | Recover Mac device sessions from internal cancellation |
| [#141](https://github.com/FoxBai/DroidMatch/pull/141) | `eef0de2a3cad4137d890f2fd26e58ef83eb535d3` | Resume file-browser search after busy work |
| [#142](https://github.com/FoxBai/DroidMatch/pull/142) | `aabdb188b5789c66cb89729a4d7dc6e8249585dc` | Bind product USB evidence to reviewed identities |
| [#143](https://github.com/FoxBai/DroidMatch/pull/143) | `df3c94f04d11fe5842712830e71d5b8535f1a025` | Bind file-browser mutations to displayed context |
| [#144](https://github.com/FoxBai/DroidMatch/pull/144) | `335ddd862289ae88f40547aec9030f08d5ce1bb3` | Make SAF grant changes transactional |
| [#145](https://github.com/FoxBai/DroidMatch/pull/145) | `7f13174645cc0f22fa5c2069135a75b8c97716ab` | Bind media previews to browser contexts |
| [#146](https://github.com/FoxBai/DroidMatch/pull/146) | `8aef32a0a9e99c033dc21d2499db14e399684c4d` | Make MediaStore upload cancellation transactional |
| [#147](https://github.com/FoxBai/DroidMatch/pull/147) | `c4489d2ba98ccf13919d46216967c5021a631a72` | Guard trust revocation during Keychain refresh |
| [#148](https://github.com/FoxBai/DroidMatch/pull/148) | `651961892e720e9b76ec45fb2800880d96c4b7f4` | Recover damaged pairing records safely |
| [#149](https://github.com/FoxBai/DroidMatch/pull/149) | `b5147ddb13dcbbe9fb12935bbfdd13f0c66e0353` | Make product MediaStore cancellation transactional |
| [#150](https://github.com/FoxBai/DroidMatch/pull/150) | `7a6f8f375758192fbe0fc7ace9c0e598358df2d2` | Isolate malformed Keychain selectors |

## Changed files / 改动文件

- `.github/workflows/m0.yml`
- `android/README.md`
- `android/app/src/main/java/app/droidmatch/m1/AdbEndpoint.java`
- `android/app/src/main/java/app/droidmatch/m1/AndroidPairingCredentialStore.java`
- `android/app/src/main/java/app/droidmatch/m1/ConnectionShutdownCoordinator.java`
- `android/app/src/main/java/app/droidmatch/m1/ConnectionStatusController.java`
- `android/app/src/main/java/app/droidmatch/m1/DmFileProvider.java`
- `android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java`
- `android/app/src/main/java/app/droidmatch/m1/DroidMatchApplication.java`
- `android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java`
- `android/app/src/main/java/app/droidmatch/m1/EndpointDrain.java`
- `android/app/src/main/java/app/droidmatch/m1/ForegroundConnectionService.java`
- `android/app/src/main/java/app/droidmatch/m1/ForegroundEndpointLifecycle.java`
- `android/app/src/main/java/app/droidmatch/m1/PairedDeviceManager.java`
- `android/app/src/main/java/app/droidmatch/m1/PairingCredentialRepository.java`
- `android/app/src/main/java/app/droidmatch/m1/PairingCredentialVault.java`
- `android/app/src/main/java/app/droidmatch/m1/ProviderPathCoordinator.java`
- `android/app/src/main/java/app/droidmatch/m1/ProviderUploadWriters.java`
- `android/app/src/main/java/app/droidmatch/m1/RpcTransferHandler.java`
- `android/app/src/main/java/app/droidmatch/m1/RpcTransferRegistry.java`
- `android/app/src/main/java/app/droidmatch/m1/RpcTransferStreams.java`
- `android/app/src/main/java/app/droidmatch/m1/SafGrantStatePolicy.java`
- `android/app/src/main/java/app/droidmatch/m1/SafPickerLaunchGuard.java`
- `android/app/src/main/res/values-zh-rCN/strings.xml`
- `android/app/src/main/res/values/strings.xml`
- `android/app/src/test/java/app/droidmatch/m1/AdbEndpointAdmissionTest.java`
- `android/app/src/test/java/app/droidmatch/m1/ConnectionShutdownCoordinatorTest.java`
- `android/app/src/test/java/app/droidmatch/m1/ConnectionStatusControllerTest.java`
- `android/app/src/test/java/app/droidmatch/m1/EndpointDrainTest.java`
- `android/app/src/test/java/app/droidmatch/m1/PairedDeviceManagerTest.java`
- `android/app/src/test/java/app/droidmatch/m1/PairingCredentialVaultTest.java`
- `android/app/src/test/java/app/droidmatch/m1/ProviderUploadWritersTest.java`
- `android/app/src/test/java/app/droidmatch/m1/RpcUploadDestinationLeaseTest.java`
- `android/app/src/test/java/app/droidmatch/m1/SafGrantStatePolicyTest.java`
- `android/app/src/test/java/app/droidmatch/m1/SafPickerLaunchGuardTest.java`
- `docs/android-code-overview.md`
- `docs/android-permissions.md`
- `docs/architecture.md`
- `docs/ci-cd.md`
- `docs/decision-log.md`
- `docs/m1-device-matrix.md`
- `docs/m1-integration-2026-09.md`
- `docs/m1-status-zh.md`
- `docs/m1-status.md`
- `docs/m1-testing-guide-zh.md`
- `docs/m1-testing-guide.md`
- `docs/mac-code-overview.md`
- `docs/maintainer-runbook.md`
- `docs/protocol-runtime.md`
- `docs/protocol.md`
- `docs/security-model.md`
- `docs/technical-debt.md`
- `fixtures/product-usb-insertion/README.md`
- `mac/App/Info.plist`
- `mac/README.md`
- `mac/Sources/DroidMatchApp/DeviceDashboardView.swift`
- `mac/Sources/DroidMatchApp/DeviceSessionPanel.swift`
- `mac/Sources/DroidMatchApp/FileBrowserItemViews.swift`
- `mac/Sources/DroidMatchApp/ProductFileBrowserView.swift`
- `mac/Sources/DroidMatchAppSupport/ProductFileBrowserSearchState.swift`
- `mac/Sources/DroidMatchCore/AdbClient.swift`
- `mac/Sources/DroidMatchCore/AsyncActiveUploadCancellationController.swift`
- `mac/Sources/DroidMatchCore/AsyncTransferScheduler.swift`
- `mac/Sources/DroidMatchCore/AsyncTransferSchedulerControlPolicy.swift`
- `mac/Sources/DroidMatchCore/AsyncTransferSchedulerJobRecord.swift`
- `mac/Sources/DroidMatchCore/AsyncTransferSchedulerJobRunner.swift`
- `mac/Sources/DroidMatchCore/AsyncTransferSchedulerPersistence.swift`
- `mac/Sources/DroidMatchCore/AsyncUploadCoordinator.swift`
- `mac/Sources/DroidMatchCore/DeviceDiscovery.swift`
- `mac/Sources/DroidMatchCore/PairingCredentialStore.swift`
- `mac/Sources/DroidMatchCore/ProcessRunner.swift`
- `mac/Sources/DroidMatchPresentation/DeviceDiagnosticsModel.swift`
- `mac/Sources/DroidMatchPresentation/DeviceSessionModel.swift`
- `mac/Sources/DroidMatchPresentation/DirectoryBrowserModel.swift`
- `mac/Sources/DroidMatchPresentation/DirectoryBrowserPresentationTypes.swift`
- `mac/Sources/DroidMatchPresentation/DirectoryBrowserPreviewState.swift`
- `mac/Sources/DroidMatchPresentation/TrustedDevicesModel.swift`
- `mac/Tests/DroidMatchAppSupportTests/ProductFileBrowserSearchStateTests.swift`
- `mac/Tests/DroidMatchCoreTests/AsyncMediaStoreProductCancellationTests.swift`
- `mac/Tests/DroidMatchCoreTests/AsyncTransferSchedulerPauseTests.swift`
- `mac/Tests/DroidMatchCoreTests/ConcurrencyAndProcessTests.swift`
- `mac/Tests/DroidMatchCoreTests/DeviceDiscoveryTests.swift`
- `mac/Tests/DroidMatchCoreTests/PairingCredentialStoreTests.swift`
- `mac/Tests/DroidMatchPresentationTests/DeviceDiagnosticsModelTests.swift`
- `mac/Tests/DroidMatchPresentationTests/DeviceSessionModelTests.swift`
- `mac/Tests/DroidMatchPresentationTests/DirectoryBrowserModelTests.swift`
- `mac/Tests/DroidMatchPresentationTests/DirectoryBrowserMutationAndMediaTests.swift`
- `mac/Tests/DroidMatchPresentationTests/DirectoryBrowserPolicyTests.swift`
- `mac/Tests/DroidMatchPresentationTests/DirectoryBrowserPreviewContextTests.swift`
- `mac/Tests/DroidMatchPresentationTests/TrustedDevicesModelTests.swift`
- `tools/build-mac-app.sh`
- `tools/check-live-doc-truth.py`
- `tools/check-m0.sh`
- `tools/check-m1-skeleton.sh`
- `tools/check-mac-app-bundle.py`
- `tools/check-maintainer-contract.py`
- `tools/check-product-runtime-freshness.py`
- `tools/check-product-usb-insertion-logs.sh`
- `tools/git-evidence-provenance.sh`
- `tools/m1-fault-proxy.py`
- `tools/mac-app-publication-cleanup.sh`
- `tools/mac-bundle-check-retry.sh`
- `tools/maintainer_android_provider_contract.py`
- `tools/product-device-visible.swift`
- `tools/product-usb-adb-v1.json`
- `tools/product-usb-adb-v2.json`
- `tools/product-usb-device-identity.py`
- `tools/product-usb-selected-devices-v1.json`
- `tools/product_usb_adb_identity.py`
- `tools/product_usb_registry.py`
- `tools/render-mac-icon.swift`
- `tools/run-product-usb-insertion-smoke.sh`
- `tools/test-build-mac-app.sh`
- `tools/test-check-live-doc-truth.py`
- `tools/test-check-mac-app-bundle.py`
- `tools/test-check-maintainer-contract.py`
- `tools/test-generate-swift-proto.sh`
- `tools/test-git-evidence-provenance.sh`
- `tools/test-m1-fault-proxy.py`
- `tools/test-mac-bundle-check-retry.sh`
- `tools/test-product-usb-device-identity.py`
- `tools/test-product-usb-insertion-logs.sh`
- `tools/test-product-usb-insertion-matrix.sh`
- `tools/test-product-usb-insertion-smoke.sh`
- `tools/test-render-mac-icon.sh`
