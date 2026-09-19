# Installed APK export / 已安装 APK 导出

The Mac Applications page exports the installed code of one explicitly selected,
visible launcher app. A standalone installation produces its unchanged `.apk`.
A split installation produces a `.zip` containing `base.apk`, every installed
split under generated `split-<index>.apk` names, and `manifest.json` with package
version/update metadata, split names, sizes and SHA-256 digests. The archive
describes the source device's installed set, not every possible ABI/language/DPI
variant. It is not bundletool `.apks`, an app-data backup, or a universal installer.

中文：Mac“应用”列表逐项导出。普通应用保存原始 APK；分包应用保存全部已安装分包和
校验清单的 ZIP。归档面向源设备配置，不包含应用数据，也不承诺可在其他设备直接安装。

## Product and consent / 产品与授权

- On Android, enable secure USB, application metadata sharing, and the separate
  **Allow APK export** switch. Both sharing generations are required; stopping
  secure USB, trust mutation, or process exit clears consent. Turning metadata
  sharing off also clears export consent. Regrant never revives an old snapshot.
- On Mac, choose **Export APK**, then an output folder through the native panel.
  A package-derived unique filename prevents replacing an existing file. The
  folder's security scope remains held through asynchronous cancellation/cleanup.
- Progress distinguishes preparation, byte transfer and final validation.
  Cancellation closes the fresh export connection and discards only the verified
  unpublished partial. Uncertain local publication preserves recovery state and
  asks the user to inspect the folder; it is never automatically retried.
- A complete atomic publication remains successful if cancellation arrives later.
  Hiding the last Applications view cancels work, rejects late presentation and
  keeps new admission closed until the previous client really exits.

中文：授权默认关闭；应用列表共享不等于安装包导出授权。已配对的 Mac 仍须通过当前
手机授权。导出结束或取消清理完成后才释放 Mac 目录访问权限。

## Wire contract / 协议约定

`CAPABILITY_APK_EXPORT = 11` is paired-only and also requires `FILE_READ`.
Nonce-only debug sessions never receive it. There is one immutable export lease
per RPC connection; a new prepare invalidates the old lease, and teardown clears
it. Other authenticated sessions cannot use its random lowercase UUID.

| Payload | Meaning |
|---|---|
| 520 / 521 | Prepare an exact package identifier; return the complete installed set |
| 522 / 523 | Revalidate the same set after all component downloads |

Requests are at most 1 KiB. Prepare responses are at most 128 KiB and validation
responses at most 1 KiB. A manifest contains 1–256 components, at most 8 GiB each
and 64 GiB total. Index zero has an empty split name and is the base APK. Later
indices are contiguous with unique 1–160-character ASCII split names containing
letters, digits, underscore, dot or hyphen. Version/update fields fit signed 64-bit
values; zero is retained as unknown metadata. Incomplete, malformed or oversized
sets fail instead of becoming base-only backups.

Each component uses the reserved fresh-only download path
`dm://apk-export/<export-uuid>/<component-index>.apk`. Generic listing, upload,
mutation, partial cleanup and persistent queue routes cannot access this namespace.
The transfer fingerprint carries the component size, zero modification time and
`<export-uuid>:<component-index>` as an opaque session-only etag. Existing chunk
CRC, offsets and 4-chunk / 2-MiB window bounds remain unchanged. Mac checks that
the open response matches its manifest and acknowledges only accepted bytes.

The final validation response is the source-consistency observation before local
publication. A subsequent independent phone update cannot retract an already
received valid snapshot; no cross-device atomic transaction is claimed.

## Provider and output ownership / Provider 与文件所有权

`ApkExportCatalog` is the provider port. `AndroidApkExportCatalog` queries only
enabled, exported launcher activities in the selected current-user package,
preserving the existing scoped package-visibility declaration. It requests no
new Android permission and reads no app data. Android's
[ApplicationInfo](https://developer.android.com/reference/android/content/pm/ApplicationInfo)
distinguishes code APKs from their public resource portions; differing code/public
paths (including forward-locked resource-only packages) are rejected. Split names,
code paths and public paths must describe the same complete set.

The provider binds package version/update time, the complete component name/path
set, and each regular file's device/inode/size/mode/owner/group/link count and
modification/change timestamps. Descriptors open read-only with `O_NOFOLLOW`
and atomic close-on-exec. API 26 uses the existing Android Linux UAPI
[`O_CLOEXEC` value](https://android.googlesource.com/platform/bionic/+/android-8.0.0_r1/libc/kernel/uapi/asm-generic/fcntl.h)
because the SDK exposes that constant only from API 27; no hidden API is called.
Every chunk checks consent, package visibility/metadata, and both the open file
and named file identity before and after reading. Full set identities are checked
at preparation, component completion and final validation. Android
[StructStat](https://developer.android.com/reference/android/system/StructStat)
has nanosecond timestamps from API 27; API 26 combines second-resolution stat
with package update/version and installed paths. This does not defend against a
privileged actor rewriting Android's package database and code in place.

`ApkExportLease` owns live generations and bounded session paths; the dispatcher
only routes prepare/validate and the shared transfer engine moves bytes. Platform
paths, exceptions, descriptors and the installed inventory do not enter wire
errors, ordinary logs or diagnostics.

Mac Core owns the fresh authenticated client, source validation, checksums and
ZIP64 streaming. The ZIP store method preserves exact signed APK bytes, uses no
whole-APK buffer or extra Android staging copy, and writes one private partial.
The existing pinned-directory/namespace-lock writer publishes with an atomic
no-replace rename only after the complete set passes validation. Unpublished
disposal requires the same locked inode; swapped names and uncertain commit
markers are preserved. The existing same-UID advisory-lock and power-loss limits
still apply. Presentation owns view/task generations; App owns the native folder
panel and scope. Export tokens never enter the persistent transfer queue.

## Verification boundary / 验证边界

Focused JVM checks cover separate consent, revoke/regrant, session replacement,
complete-set limits, private-path isolation and source changes. Swift checks use
a real local paired TCP connection for single/split exports, checksum manifests,
ordinary ZIP-reader interoperability, cancellation, final source changes, and
atomic cleanup refusing a replaced partial. Presentation checks verify draining,
scope release, stale results and late cancellation after publication. Native
view inspection uses synthetic applications and opens/cancels the folder panel.

No physical APK export, OEM compatibility, public-release approval or new M1 device
evidence is claimed. Split installation, app-data backup, uninstall, broader app
visibility and distribution-channel approval remain separate work.
