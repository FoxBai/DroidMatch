# APK Installation / APK 安装

This optional product flow sends one standalone `.apk` from a paired Mac and
requests an ordinary Android system installation. It does not add silent
installation, uninstall, split-bundle installation, APK export, or app-data backup.
The feature has local protocol, lifecycle and synthetic UI coverage; actual Android
installation, OEM prompts, source-settings behavior and update compatibility still
need an attended device run. It closes no physical M1 criterion.

中文：此功能接收单个独立 APK，并由手机用户批准、交给 Android 系统安装。它仍是可选
功能，不改变 v1.0 发布范围。当前没有真机条件；本地验证不代表系统安装或 OEM 兼容性
已经通过。静默安装、卸载、分包安装、APK 导出和应用数据备份均未包含。

## Product flow / 使用流程

1. On Android, enable secure USB. In **Install APKs**, open installation permission
   settings and allow DroidMatch as a source, then enable incoming installation
   requests. This is separate from sharing the application list.
2. On Mac, open **Applications → Install APK → Choose APK**. Select one regular
   file, 1 byte through 1 GiB, with a visible filename ending in `.apk` and at most
   160 Unicode scalars. The native file panel owns the temporary security scope.
3. Mac hashes and uploads the same open file snapshot. Android verifies its exact
   size and SHA-256 before showing the request as ready for approval. Keep the
   installation window open until transfer cleanup finishes; Cancel remains
   available during the transfer. The existing general file queue is unchanged.
4. On the phone, approve that request, then choose **Open Android confirmation**
   when the system callback arrives. The filename is supplied by the Mac and is
   not verified package identity; Android validates the application and signature.
5. Mac polls the current authenticated owner's records. A final upload ACK means
   transfer integrity was verified. Only a matching successful system callback
   means installation succeeded.

中文：手机先允许安装来源并打开“接收 APK 安装请求”；Mac 选择文件并完成传输。之后
仍需在手机上批准该请求、打开系统确认。文件名只帮助识别请求，实际应用与签名由
Android 验证。文件上传完成不能显示成安装成功。

## Protocol and ownership / 协议与归属

- Additive `CAPABILITY_APK_INSTALL = 10` is paired-only. Payloads 510/511 prepare,
  512/513 list, and 514/515 cancel an operation. There is no commit or launch RPC.
- A private SHA-256 owner identifier is derived from the pairing ID only after
  successful proof. The provisional pairing ID is then cleared. Nonce-only
  sessions have neither that owner nor installation capability.
- Prepare binds a lowercase UUID, normalized display name, expected size and
  32-byte SHA-256 to that owner. Reusing an ID is idempotent only for the exact
  same owner's same request. At most one operation is active globally, and the
  journal holds at most eight records; listing returns only the requesting owner.
- The returned upload destination is exactly
  `dm://apk-install/<operation-uuid>/base.apk`. Transfer ID must equal the UUID,
  expected size must match, and requested offset must be zero. Upload requires
  both `FILE_WRITE` and `APK_INSTALL`, current source permission and the original
  live consent generation. Generic browsing, mutation, download and resumable
  partial disposal do not access this namespace.
- Bytes go directly to `PackageInstaller.Session.openWrite`, not a shared file
  provider. Existing CRC, offset, negotiated chunk, four-chunk/two-MiB window and
  session stream limits apply. Integrity, `fsync` and output closure precede
  approval. This first installation upload is fresh-only: interruption requires
  cleanup and an explicit fresh request. General transfer resume is unchanged.
- RPC requests are at most 2 KiB. Mac validates prepare/cancel replies at 2 KiB
  and list replies at 8 KiB before parsing, including operation IDs, filenames,
  counts, unsigned sizes, progress and state/error consistency. No platform
  session number, callback token, Intent, content URI or filesystem APK path is
  returned. Normal diagnostics include none of these records or filenames.

中文：安装记录只属于完成认证的 Mac。默认关闭的本次连接授权、系统来源权限、每次
手机批准和系统确认是不同边界。停止安全连接、撤销信任或服务退出会立即关闭接收
授权；较慢的私有会话清理在后台执行，重新授权也不能复活旧传输。

## Android state and recovery / 手机状态与恢复

`ApkInstallManager` owns admission, upload integrity, durable transitions and
callback reconciliation. `AndroidApkInstallBackend` owns only platform sessions
and confirmation Intents. `ApkInstallRuntime` serializes UI work off-main; the
Activity renders immutable snapshots and performs foreground gestures. The
non-exported `ApkInstallResultReceiver` queues the explicit callback for validation.

The private versioned journal is one bounded synchronous SharedPreferences value.
It stores operation/owner/session identity, expected integrity and lifecycle, but
never grants incoming consent after restart. Both backup and device-transfer
rules exclude it. Existing unreadable preference XML, its backup, invalid records,
duplicate identities or failed writes fail closed instead of becoming a fresh
empty journal. Uncertain installer sessions are preserved for investigation.

| State / 状态 | Behavior / 处理 |
|---|---|
| Waiting/uploading / 等待或传输中 | Stop, cancellation or interruption abandons only the owned session; a failed cleanup remains retryable. |
| Waiting for phone approval / 等待手机批准 | Exact size and SHA-256 passed; the phone can approve or cancel. Mac cannot submit it. |
| Submitting / 已提交请求 | The journal records submission intent before the SDK call. Revocation before admission prevents submission. After admission, the system outcome must be reconciled. |
| Waiting for system / 等待系统 | Only a phone foreground button launches the returned confirmation Intent. Reconnect, callbacks and app activation never launch or resubmit automatically. |
| Succeeded/failed/cancelled / 终态 | A matching platform result determines the installation outcome. Pre-submission errors remain transfer/request failures. |
| Unknown / 结果未知 | Restart after submission, an ambiguous SDK call, an unanswered initial submission after ten seconds, or a vanished session without a terminal result produces unknown, never success. Late valid callbacks may still settle it. |
| Cleanup required / 待清理 | Abandonment must be verified before another request can start. Merely losing an in-memory writer is not success. |

Each result must match the operation, private installer session ID and a random
32-byte callback identity. The explicit mutable PendingIntent supports both
pending and terminal callbacks; it is deliberately not one-shot. Unknown future
platform statuses remain unknown. Raw platform error messages are never forwarded.

For an unknown result, the phone presents a separate confirmation explaining that
the user must first check whether installation occurred. Resolving it attempts to
abandon any remaining owned session and verifies its absence before allowing a
new request. The record remains **unknown**, not successful, and no reinstall is
scheduled. Late pending or uncertain callbacks cannot reactivate a dismissed
record; a matching terminal callback can still settle it without blocking a newer
request. / 旧未知结果经手机处理后，迟到的非最终回调不能重新占用安装名额；有效最终结果仍可更新。
Untracked DroidMatch-owned sessions similarly need explicit phone
cleanup; corrupt journal state never authorizes adopting or abandoning them.

API 31+ uses `USER_ACTION_REQUIRED`. The manifest declares only
`REQUEST_INSTALL_PACKAGES`; privileged installer permissions and device/profile
owner operation are rejected. No ADB install command, permission pregrant or silent
update path is used. Source trust is checked live at admission and approval.

## Mac ownership / Mac 生命周期

`ProductApkInstallationClient` uses the product control session for bounded
read-only status. Upload and cancellation use fresh paired clients behind their
own invalidatable session gate. Interrupted preparation gets best-effort
pre-submission cleanup; unresolved state remains visible on reconnect. There is
no automatic resend. Teardown closes clients before releasing the device forward.

`ApkInstallationModel` publishes only for its current session/view generation.
The App balances native-panel security scope after the upload descriptor and
cancellation cleanup close, including a late result after the view disappears.
No Mac installation journal, local staged APK, persistent inventory or new
diagnostic contents are added.

## Validation and next evidence / 验证与后续证据

Local coverage includes owner/nonce isolation, consent revocation, integrity and
interruption, failed commit-intent persistence, callback identity, uncertain
outcomes, cleanup retry, corrupt-journal preservation, bounded wire decoding,
fresh paired TCP upload and stale-view/scope completion. The synthetic TCP payload
is test data, not an installed APK. The native view fixture uses synthetic rows
without device discovery or installation.

When an attended disposable Android device is available, validate source permission
and its revocation, valid/invalid/changed/split-only APKs, new install/update,
system rejection, user cancellation, app/process restart, lost result and cleanup,
Mac disconnect/reconnect, multi-Mac isolation and OEM confirmation behavior. Follow
the opt-in and cleanup requirements in [M1 Testing Guide](m1-testing-guide.md).
No physical fixtures are added by the local implementation.

APK export and distribution-channel review remain in the [Project Backlog](project-backlog.md).
Developer ID signing, notarization and release automation remain deferred.

Primary platform references checked 2026-09-06:
[user action policy](https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int)),
[live source permission](https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls()),
[session and callback contract](https://developer.android.com/reference/kotlin/android/content/pm/PackageInstaller.Session),
and [SharedPreferences read failure behavior](https://android.googlesource.com/platform/frameworks/base/+/master/core/java/android/app/SharedPreferencesImpl.java).
