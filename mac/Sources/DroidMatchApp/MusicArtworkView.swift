import DroidMatchAppSupport
import SwiftUI

/// Render changed bytes directly, including inside native button labels. The
/// equatable boundary avoids decoding again for unrelated playback progress.
/// 中文：按当前数据直接渲染，避免按钮标签内生命周期回调遗漏封面更新。
struct MusicArtworkView: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Artwork(data: data, size: size).equatable()
    }

    private struct Artwork: View, Equatable {
        let data: Data?
        let size: CGFloat

        var body: some View {
            Group {
                if let image = MediaArtworkImage.decode(data) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: min(64, size * 0.45), weight: .light))
                        .foregroundStyle(.blue)
                }
            }
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: size * 0.06))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.06))
            .accessibilityHidden(true)
        }
    }
}
