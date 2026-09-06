# Project Backlog / 全项目待办

Last updated / 更新日期：2026-09-06

This is the remaining product work across releases, not just the M1 device gate.
Implemented behavior and accepted physical evidence remain in
[M1 Status](m1-status.md); release scope follows [Product Scope](product-scope.md)
and [Feature Matrix](feature-matrix.md).

本文区分可继续开发的产品功能、等设备的验收、暂缓的发行工作和后续版本规划。
目前没有真机测试条件，但这不阻止离线产品开发。只补与变更相关的必要验证；
已通过的检查不反复扩充，未执行的真机项目不标完成。

## Next product work / 接下来可推进的产品工作

| Priority / 顺序 | Work / 工作 | Current boundary / 当前边界 |
|---|---|---|
| 1 | Video playback completion / 视频播放收尾 | Native play/pause/seek now uses authenticated bounded reads and has local synthetic evidence. Device playback, codecs, large-file seek latency, and OEM/provider compatibility still need real observations. / 播放、暂停、定位已实现并本地验证；真机兼容性与大视频定位体验待验证。 |
| 2 | Basic music / 基础音乐管理 | [Basic list, search/sort, duration, import/export and live audio authorization](basic-music.md) are implemented with local coverage; real-device validation, playback, artwork, and song/album/artist views remain open. Still optional in v1.0 and required in v1.1. / 基础列表、导入导出和授权已实现；真机验证、播放、封面、专辑与歌手等视图待完善。 |
| 3 | Applications and APKs / 应用与 APK | Optional in v1.0. [Application metadata/list, search/sort and explicit sharing](application-library.md) are implemented with scoped launcher visibility. System-confirmed installation, permitted split-aware APK export, build-channel review, and device validation remain open. Silent installation/uninstallation is out of scope. / 应用列表、搜索排序和显式共享已实现；系统确认安装、允许的分包 APK 导出、渠道评估与真机验证待做。 |
| 4 | v1.1 refinement / v1.1 体验完善 | Improve thumbnail caching/indexing, batch-operation feedback, media navigation, and supported video formats based on concrete use cases. Existing browsing, mutations, multi-select, and persistent transfer controls are implemented. / 在现有浏览、批量选择和传输队列基础上优化，不把已有功能重列为未实现。 |

These priorities sequence the existing roadmap; optional music/APK work does not
become a new v1.0 release requirement. Android remains the connection, pairing,
trust, and authorization companion, not a full local file manager.

以上是开发顺序，不把可选功能升级为 v1.0 的硬性发布条件。Android 端仍定位为连接、
配对、信任与授权管理，不扩成完整本地文件管理器。

## Waiting for devices / 等真机条件恢复

- **ADB M1 blockers:** current-candidate release download/upload throughput on
  Slot A, and attended product USB insertion at or below five seconds on
  Slots A/C/D. / Slot A 当前候选吞吐与 A/C/D 产品 USB 插入耗时是尚未关闭的 M1 门槛。
- **Additional product validation:** application visibility, sharing revocation/regrant and OEM behavior; real video playback and seek; Music indexing/import visibility and audio transfer interruption; media access
  selection/reselection in the product UI; SAF permission loss during transfer;
  accessibility and device/provider compatibility. Existing historical evidence
  is not rewritten to cover these changes. / 新功能和权限交互按实际操作补证据，不沿用旧日志冒充。
- **AOA:** implement and evaluate the experimental transport after the ADB M1
  path; promotion requires its own two-device gate. / AOA 尚待实现及双设备验证，当前不提升为默认通道。

The exact admitted runners and gate definitions are in
[M1 Testing Guide](m1-testing-guide.md) and
[M1 Exit Criteria](m1-status.md#m1-exit-criteria-progress).

## Deferred distribution / 暂缓的发行工作

Developer ID signing, notarization, release automation, and the independent human
review required before public beta/stable release remain open. The owner has
deferred that release path; do not request credentials or submit to Apple until
explicitly reopened. Local ad-hoc App/DMG assembly and repository main integration
remain in scope. / 正式签名、公证、发布自动化及公开发布前独立人工审查仍待做，按当前授权暂缓；
本地 App/DMG 交付与 main 同步继续进行。

## Later versions / 更后续版本

Screen mirroring, notification mirroring, clipboard synchronization, folder
subscriptions, and a complete Wi-Fi discovery/encryption/reconnect design remain
roadmap items. Each requires its own permission and privacy design; none is part
of the current v1.0 baseline. / 投屏、通知镜像、剪贴板同步、文件夹订阅和完整 Wi-Fi 通道尚未实现，
分别设计授权与隐私边界后再推进。
