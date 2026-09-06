# Application Library / 应用列表

The Mac Applications page lists application metadata explicitly shared by the
Android companion. This is the first application/APK increment: system-confirmed
installation and permitted, split-aware APK export remain open in the
[project backlog](project-backlog.md). Application data, usage history, permissions
inventory, APK paths, and icons are outside this read-only surface.

中文：Mac“应用”页已实现应用列表、名称/包名搜索、名称/最近更新时间排序、分页刷新，
以及版本、构建号、更新时间和系统应用标识。系统确认安装和允许的 APK 导出仍待实现；
本功能不读取应用私有数据、使用记录、权限清单或 APK 路径。

## Consent and visibility / 授权与可见性

- A paired, authenticated product session must negotiate
  `CAPABILITY_APPLICATION_LIST = 9`. The nonce-only debugging endpoint never
  advertises this capability. Existing peers show an update-required state.
- Android requires an explicit **Share application list** action while secure USB
  is ready. Consent defaults off, exists only in memory, and clears on explicit
  secure-USB stop, trust mutation, service destruction, or process exit. It is
  separate from ADB authorization, pairing, media permissions, and SAF grants.
- Each query rechecks consent before platform enumeration, during metadata
  collection, and before returning data. An off/on change creates a new generation;
  it cannot revive a pending request or cursor from the previous grant.
- PackageManager queries only `ACTION_MAIN` plus `CATEGORY_LAUNCHER` for the
  current Android user. Only enabled applications with an enabled, exported
  launcher activity are projected; duplicate activities become one package row.
  Non-launchable applications and other user/profile inventories are not requested.
- The manifest declares that exact scoped intent query. It adds no
  `QUERY_ALL_PACKAGES`, installation, or storage permission. The release manifest
  gate rejects a broader query. Build-channel publication policy still needs
  review before distribution; this implementation does not claim store approval.

This follows Android's [scoped package-visibility declarations](https://developer.android.com/training/package-visibility/declaring).
The broad-inventory [Google Play policy](https://support.google.com/googleplay/android-developer/answer/12085295?hl=en)
does not provide blanket distribution approval for this feature.

中文：Android 必须在安全 USB 就绪后主动开启共享。授权只在当前进程内有效，停止安全
USB、修改信任、服务销毁或进程退出后会关闭。每次查询重新检查授权代次和当前可见性；
只查询当前用户有可启动入口的应用，不申请全量包可见性权限，也不推断其他用户资料。
发行渠道适配与商店审核仍是后续工作。

## Wire and bounded paging / 协议与分页边界

`proto/v1/application.proto` is the wire source. Protocol version remains 1.0;
the capability and payload values are additive. Request payload type `500` and
response payload type `501` use the existing control request-ID, timeout,
authentication, and read-only cancellation rules.

| Value | Bound or meaning |
|---|---|
| `page_size` | 1–100; wire zero selects 50; Mac requests 100 |
| `query` | At most 128 Unicode scalars; hidden controls and line separators rejected |
| Sort | Name or update time, then package ID as stable tie-breaker; optional descending |
| Inventory | At most 8,192 launcher results and 4,096 unique applications |
| Package identifier | At most 255 ASCII characters in the package-identifier grammar |
| Display/version text | NFC, at most 160 visible scalars; normalization input capped at 2,048 UTF-16 units |
| Version/update | Nonnegative signed-64-bit platform values encoded as `uint64` |
| Response | Mac rejects payloads over 256 KiB, duplicate IDs, invalid metadata, or inconsistent pagination |
| Cursor | Exactly 92 unpadded base64url characters when present; opaque to Mac |

Each page re-enumerates the current catalog. A cursor includes a version, offset,
SHA-256 snapshot, and HMAC-SHA256 made with a random provider-local key. Its
snapshot binds the session, consent generation, query, page size, ordering, and
matching metadata. A changed snapshot, forged cursor, cross-session replay, or
provider replacement returns `INVALID_ARGUMENT` and requires refresh. Disabled
or changed consent returns `PERMISSION_REQUIRED`; platform failures return a
fixed error without metadata. There is no persistent inventory or cursor store.

These limits bound application-owned projection and retention. PackageManager
may first materialize its result inside Android; no portable total framework-heap
ceiling is claimed. Already displayed metadata cannot be retroactively unread.
Foreground activation, refresh, and subsequent pages recheck access; Android
does not send a push revocation event for this surface.

中文：分页 token 同时绑定会话、授权代次、查询/排序/页长与当前结果快照。应用变化、
重新授权、跨会话或伪造 token 都必须刷新。库存和文本均有上限，但不声称能控制 Android
框架内部的全部分配。已经展示的信息不能撤回；页面重新激活、刷新或翻页会再次验证，
当前没有单独的授权撤回推送事件。

## Ownership and validation / 职责与验证

Android `ApplicationAccess` owns process-local consent; `AndroidApplicationCatalog`
owns PackageManager access; `ApplicationListProvider` owns projection, paging, and
live admission. Dispatcher/control handlers only route admitted RPCs.

Mac Core `ApplicationLibraryClient` and its async adapter own protocol validation.
`ApplicationLibraryModel` owns task generations, clear-on-error state, search,
sorting, and pagination. `ProductApplicationLibraryView` consumes domain values.
The last visible Applications view detaching, session replacement, or failure
clears retained rows. Cancelled late replies are drained and still wire-validated.
Application labels, package inventories, queries, and cursors never enter normal
logs or diagnostics.

Targeted JVM checks cover consent/regrant races, cursor bindings, bounded private
errors, and nonce-versus-paired routing. Swift checks cover wire validation,
unsupported peers, late results, and pagination. The actual product view has a
local synthetic fixture for English/Chinese states and interactions. No physical
application-list observation or APK installation/export evidence is claimed.

中文：本地验证覆盖授权、分页、协议边界和产品模型；原生界面使用合成应用数据检查。
真机应用可见性、共享开关与 OEM 行为仍待设备条件恢复后验证，不增加真机通过项。
