import AppKit
import ImageIO

/// Validate encoded artwork and its real dimensions before allocating pixels.
/// Wire metadata is descriptive; it cannot authorize a larger native image.
/// 中文：先复核图片头和实际尺寸，再解码音乐封面，不信任远端尺寸声明。
@MainActor public enum MediaArtworkImage {
    public static func decode(_ data: Data?) -> NSImage? {
        guard let data, !data.isEmpty, data.count <= 512 * 1024 else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String?,
              type == "public.jpeg" || type == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...512).contains(width.intValue), (1...512).contains(height.intValue),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == width.intValue, image.height == height.intValue,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
