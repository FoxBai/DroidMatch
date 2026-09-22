# Music metadata / 音乐信息

Music rows and previews display a provider title with artist and album when
available. Missing tags keep the filename fallback. The preview also shows the
original filename when its title differs; downloads and file operations always
use that original name and canonical item path. Name sorting is explicitly
labeled **File name** in Music. Audio search includes filename, title, artist
and album through the same paged provider query.

音乐列表及预览可显示系统提供的歌曲标题、歌手和专辑；没有标签时回退到文件名。
标题不同时，预览同时显示原文件名。下载与文件操作仍使用原文件名和 canonical path。
音乐排序明确标为「文件名」，搜索覆盖文件名、标题、歌手和专辑。

## Wire and provider boundary / 协议与数据边界

- `FileEntry.audio_metadata = 10` is an optional `AudioMetadata` message with
  `title = 1`, `artist = 2` and `album = 3`. Each field is at most 512 UTF-8 bytes;
  empty means unknown. Existing fields, enums, capabilities and protocol versions
  are unchanged. Old clients ignore it; an old provider keeps filename-only
  display/search. A missing audio root still shows the existing unavailable state.
- Android queries the MediaStore Audio title/artist/album columns alongside
  its existing six listing columns, only after checking live audio permission.
  It checks the grant again before returning the decoded page. Missing/null
  optional columns keep a usable file row. No file-content tag extraction,
  album-art URI, raw document ID or network lookup is introduced.
- Android rejects each raw label longer than 2,048 UTF-16 code units before NFC
  normalization. Its existing display projection strips controls/format/surrogate
  code points, collapses whitespace and caps at 120 code points, including an
  ellipsis when truncated: at most 480 UTF-8 bytes. Empty and the platform's
  unknown sentinel become absent labels.
- Mac independently rejects each incoming label over 512 UTF-8 bytes and applies
  the existing 120-scalar display projection. A malformed field becomes absent
  without rejecting valid sibling fields or the file row. Metadata is retained
  only for readable canonical `dm://media-audio/media/<id>` files with `audio/*`
  MIME; the ID must be nonnegative ASCII decimal within signed 64-bit range.
- Search remains escaped SQL `LIKE` with bound arguments. Audio adds a grouped
  OR across its four columns; existing restrictions stay outside that group.
  Other media retain filename-only search. Provider collation still determines
  matching; no accent-insensitive or normalized-tag search guarantee is added.
- Pagination limits, request ownership, file identity, source fingerprints,
  thumbnail keys, explicit Play and transfer naming remain unchanged. Metadata
  adds no authorization or playback capability. Refresh, navigation and live
  authorization invalidation use existing browser generations; a stale preview
  hides its captured heading rather than retaining old track labels.

字段只是可选展示信息。Android 查询前与返回前均检查当前音频权限；两端独立限制并清理
标签，不把它用于授权、路径或下载命名。搜索仍使用转义后的绑定参数和原分页边界。
撤权、刷新或导航使预览失效后，旧标题、歌手、专辑与文件名不再显示在预览标题区。

## Evidence and remaining work / 验证及后续

Focused local checks cover cursor projection, missing/unknown/oversized tags,
Unicode display bounds, root/MIME isolation, SQL argument boundaries, wire
round-trip and old-peer fallback, unchanged file identity, and existing preview
authorization invalidation. Synthetic native Mac views exercise English/Chinese
rows, filename fallback, preview headings and invalidation. These are local
fixtures, not Android-device evidence.

Album/artist group browsing needs a complete provider index and its own bounded
query contract; grouping only the loaded page is not implemented as a substitute.
Playlists, tag editing, device indexing/search compatibility and OEM behavior
remain open. No M1 physical gate is closed by this increment.

专辑／歌手分组浏览、播放列表和标签编辑仍未实现。真机索引、搜索与厂商兼容性待验证；
不把本地合成检查计为真机证据，也不改变 M1 验收状态。

Provider references: [Android AudioColumns](https://developer.android.com/reference/android/provider/MediaStore.Audio.AudioColumns)
and [MediaStore unknown metadata](https://developer.android.com/reference/android/provider/MediaStore#UNKNOWN_STRING).
