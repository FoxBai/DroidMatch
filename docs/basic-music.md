# Basic Music / 基础音乐管理

The Mac Media surface includes Music with bounded paging, filename search,
sorting, audio duration, multi-selection, native-panel/Finder imports and
queue-backed exports, plus explicit native play/pause/seek through authenticated
bounded reads. This is optional v1.0 scope. Artwork, playlists, and
song/album/artist indexing are later work. Android remains the connection
and authorization companion.

Mac「媒体 → 音乐」提供分页、按文件名搜索、排序、音频时长、批量选择，以及原生文件
面板/Finder 导入、传输队列导出，以及通过认证有界读取的原生播放、暂停和定位。
基础音乐仍是 v1.0 可选功能；封面、播放列表和歌曲/专辑/歌手索引后续完善。Android 继续负责连接与授权管理。

## Authorization and storage / 授权与存储

- `dm://media-audio/` is a normal MediaStore Audio root under `dm://roots/`;
  rows use `dm://media-audio/media/<id>`. Platform URIs never cross the wire.
- API 33+ uses `READ_MEDIA_AUDIO`, independent of image/video and selected-visual
  grants. API 26–32 uses the existing `READ_EXTERNAL_STORAGE` permission, which
  also covers visual media on those versions. The Android Music button requests
  it explicitly; startup and foreground return only refresh live state.
- Denial leaves Music unreadable. An explicit later button can open app Settings
  after a complete permission callback establishes that another prompt is no
  longer offered. Cancellation never automatically opens Settings.
- Each list/open/download chunk rechecks the current audio grant. A root snapshot
  cannot authorize an old descriptor after revocation. The Mac clears cached rows
  when access is rechecked or denied, without an automatic listing retry loop.
- API 29+ independently permits app-owned fresh inserts under `Music/DroidMatch`.
  An unreadable but writable root can receive imports without listing existing
  audio. API 26–28 keeps writable SAF as the import alternative; the default
  manifest does not request `WRITE_EXTERNAL_STORAGE`.

音乐权限按实时状态检查。Android 13 及以上版本的照片/视频或部分照片授权不能授予音频
读取；Android 12 及以下版本沿用同一旧版存储读取权限。撤权后旧文件描述符不能继续
依靠打开时的授权读取。Android 10 及以上版本可独立接收应用拥有的新音频；旧版使用
用户授权的可写文件夹，不新增广泛写入权限。

## Transfer and compatibility / 传输与兼容

The exact import extensions on both peers are `aac/flac/m4a/mp3/oga/ogg/opus/wav`.
Filename validation is not content decoding. Unknown, ambiguous or cross-category
names are rejected before publication. MediaStore imports remain fresh-only:
no pause/resume or automatic retry; active cancellation must confirm partial
cleanup before reporting cancellation. Existing fingerprint, CRC/offset, window,
and atomic-download rules remain unchanged.

Positive audio duration reuses `FileEntry.duration_millis` with canonical
`audio/*` MIME; zero or malformed metadata means unknown. There is no new payload,
capability, field number, or protocol version. A new Mac sees a fixed unavailable
Music state on an older Android peer that has no audio root. Older clients can
ignore the extra root/duration; native imports require the updated Mac allowlist.
The diagnostic `media_read` key keeps its existing coarse visual-media meaning;
Music authorization is exposed through the live root and Android Music status.

两端的音频导入类型一致，沿用 MediaStore 的新建、不续传规则和取消清理状态。下载继续
使用原有校验与原子提交。旧 Android 不提供音乐根目录时，Mac 显示该分类不可用。
时长只是描述信息，不授予读取或播放能力；音乐预览创建独立上下文，不请求音频缩略图。

## Native playback / 原生播放

Selecting a readable track opens a preview; only **Play Music** starts reading.
The shared native controller provides pause/resume, elapsed/duration, seeking,
and replay after the end. Closing the sheet or invalidating its browser context
closes the source and removes native observations/pending seeks. Music does not
keep the display awake or create a persistent queue job or a DroidMatch disk cache.

Admission requires a decimal MediaStore Audio item ID fitting signed 64 bits
under `dm://media-audio/media/`, matched with an audio MIME type. The native
attempt allowlist is MP3 (`audio/mpeg`, `audio/mp3`), M4A (`audio/mp4`,
`audio/x-m4a`), AAC (`audio/aac`, `audio/aac-adts`), FLAC (`audio/flac`,
`audio/x-flac`), WAV (`audio/wav`, `audio/x-wav`, `audio/vnd.wave`), and AIFF
(`audio/aiff`, `audio/x-aiff`). Admission does not promise a decoder for every
container/codec/OS combination. Ogg/Opus and other unlisted formats show a fixed
unavailable explanation while retaining download; import/export support is a
separate boundary. Corrupt or unsupported native content exposes no decoder error.

The existing paired `FILE_READ`/`RESUMABLE_TRANSFER` surface supplies one serial
range at a time, each at most 1 MiB. Every reopen verifies the original source
fingerprint and size, including offset zero; current audio permission, CRC,
offsets and the four-chunk/two-MiB window still apply. Source changes never
silently restart a different track. Native asset URLs have only random process
identity, with external references, aliases and external playback disabled.

点击曲目先打开预览，点击「播放音乐」后才读取。可暂停、继续、定位并在结束后重播；
关闭或失效会释放来源、播放器监听与待完成跳转，不保存播放任务或磁盘音频缓存。
路径与 MIME 必须同属音频类别。原生解码失败或未列入尝试范围的格式保留下载入口，
不等于所有格式或所有系统版本均已兼容。逐次读取沿用认证、源身份和实时权限检查。

## Evidence boundary / 验证边界

Focused local coverage exercises API permission boundaries, independent live root
capabilities, bounded cursor/listing metadata, safe audio paths/types, fresh upload
and active cancellation, older peers, and cache invalidation. Native Mac checks
use synthetic entries and injected clients. Paired TCP cases cover audio ranges,
category/path rejection, source changes, permission loss, CRC and close/drain;
preview cases cover explicit start, zero audio-thumbnail requests and stale
contexts. Native generated WAV/M4A checks exercise decoding, pause, seek, replay
and cleanup; malformed audio checks exercise failure/replacement. The affected cross-platform gate
validates builds and regressions; these are not physical-device evidence.

No device was available for this increment. Real MediaStore indexing/import
visibility, OEM permission UI, audio transfer interruption, physical playback,
large-file seek latency and codec compatibility
remain unverified. Existing M1 throughput/USB gates and frozen fixture archives
are unchanged. / 本轮无真机，不把本地合成验证计入设备证据；音乐实际索引、导入可见性、
厂商授权界面与中断行为仍待观察，现有 M1 门槛和历史日志保持原状。
