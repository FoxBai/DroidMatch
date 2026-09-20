# Music Artwork / 音乐封面

Music rows and the idle/playing preview can display the current Android provider's
cover image. A missing, unsupported or malformed cover retains the music-note
placeholder. Artwork does not grant playback, start an audio download, or prevent
an otherwise permitted Play/Download action. Audio playback remains explicit.

音乐列表和播放前/播放中的预览可显示系统提供的封面。没有封面、格式不支持或图片损坏
时保留音符图标，仍可按原能力播放或下载；封面不触发音频播放。

## Source and authorization / 来源与授权

- The existing paired `FILE_READ` thumbnail RPC accepts
  `dm://media-audio/media/<id>`, with the same non-negative decimal signed-64-bit
  path checks used by visual media. There are no new fields or capabilities.
- API 29+ requests a typed `image/*` asset for the exact MediaStore Audio item,
  with `ContentResolver.EXTRA_SIZE`. API 26–28 returns unsupported. An older
  companion may also reject the request; both cases retain the placeholder.
- `AndroidAudioArtwork` opens only that derivative. It never opens the original
  audio, extracts an embedded image, reads an album-art filesystem path, or calls
  a network service as a fallback. The system provider may maintain its own cache;
  DroidMatch creates no artwork disk cache.
- `ProviderAudioArtwork` checks current audio permission before opening, after
  opening, before each bounded read, before decoding, and after encoding before
  returning. Source streams close on success, failure and observed interruption.
  Photo/video selection cannot substitute for the independent audio grant on
  API 33+; API 26–32 retains its shared legacy read permission.
- Provider URIs, paths, image contents and raw decoder exceptions are absent
  from normal diagnostics and wire errors. The existing fixed thumbnail errors
  and authoritative Music permission-failure domain remain in use.

Android 10 及以上使用系统的图片派生接口；Android 8–9、旧 companion 或无法提供封面的
provider 使用音符占位。请求期间与返回前重新检查音乐读取权限，不把打开描述符时的
授权视为永久有效。系统 provider 的生成成本和缓存属于系统行为，不作真机兼容声明。

## App-side budgets / 应用侧上限

| Boundary / 边界 | Limit / 上限 |
|---|---|
| Encoded derivative input | 2 MiB; reject known larger slices before reading, and read at most one extra byte to reject an unknown-length overflow |
| Source image header | Each side at most 8,192 px and at most 32 Mi pixels, checked before pixel allocation |
| Decoded Android output | Aspect-preserving target within the requested 32–512 px, using software allocation |
| Encoded wire output | JPEG, at most 512 KiB; compression writes are capped before buffer growth |
| Mac Music image decoding | JPEG/PNG, one image, at most 512 KiB and actual header dimensions 1–512 px before pixel allocation; reject incomplete decoding |
| Background row requests | Existing four active requests, 96 px, including stale work still draining |
| User preview request | Existing one real request, 512 px, outside the row FIFO |
| Encoded browser cache | Existing 64 entries and 8 MiB; visible views own only their current decoded image |

These bound DroidMatch's input/decode/output work. The platform provider owns its
generation and blocking I/O. There is no new worker pool or promise of a hard
OEM timeout or provider-process memory limit. Admitted read-only RPCs retain their
existing deadline/drain behavior; hiding a surface invalidates publication rather
than pretending the underlying provider call has already stopped.

## Presentation lifetime / 展示生命周期

The current browser generation and opaque preview context own publication.
Closing or replacing a preview, navigating, rechecking access, or losing Music
permission cannot publish a stale cover into another preview. Permission loss
clears rows and derivatives through the existing Music authorization domain.
An old window cannot clear another window's current cover. Row failures are
deduplicated by the existing cache generation; a missing cover creates no retry
loop. A failed cover leaves the independent playback controls available.

`MediaArtworkImage` validates the actual encoded image separately from remote
width/height metadata. `MusicArtworkView` replaces its decoded image only for the
matching current bytes, and provides the same decorative fallback in a row and
the playback surface. Artwork remains hidden from accessibility; the track name
and native playback controls retain their existing labels and shortcuts.

## Evidence and remaining work / 验证与待办

Focused JVM cases exercise revocation at open/read/decode, stream closure,
oversized and interrupted input, source geometry and encoded-output budgets.
Swift covers audio RPC admission, real bounded JPEG/PNG decoding, hostile image
headers, unavailable artwork with explicit Play, and shared stale preview-context
behavior. Synthetic native UI is used for English/Chinese layout and interaction.

There is no physical-device artwork evidence. API/OEM/provider output, cover
orientation, changes to embedded artwork, real permission revocation and latency
remain to be observed on devices. Album/artist metadata/indexing and playlists
remain separate work in [Basic Music](basic-music.md) and the
[Project Backlog](project-backlog.md). Existing M1 device gates and frozen evidence
are unchanged. / 本轮无真机；实际封面来源、方向、更新、撤权及耗时仍待设备验证。

Primary platform references checked 2026-09-20:

- [ContentResolver typed asset and thumbnail API](https://developer.android.com/reference/android/content/ContentResolver).
- [Android 16 ContentResolver source](https://android.googlesource.com/platform/frameworks/base/+/android-16.0.0_r1/core/java/android/content/ContentResolver.java).
- [Android 16 MediaProvider source](https://android.googlesource.com/platform/packages/providers/MediaProvider/+/android-16.0.0_r1/src/com/android/providers/media/MediaProvider.java).

The pinned sources establish the typed thumbnail route, including Audio item
handling. They are supporting implementation evidence, not proof of every OEM's
behavior on every supported Android version.
