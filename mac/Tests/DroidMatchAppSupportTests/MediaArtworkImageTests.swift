import AppKit
import ImageIO
import Testing
@testable import DroidMatchAppSupport

@Test(arguments: ["public.png", "public.jpeg"]) @MainActor
func artworkImageDecodesBoundedNativeCovers(type: String) throws {
    let encoded = try artworkFixture(width: 96, height: 64, type: type)
    let image = try #require(MediaArtworkImage.decode(encoded))
    #expect(image.size == NSSize(width: 96, height: 64))
}

@Test @MainActor func artworkImageRejectsOversizedOrInvalidNativeImages() throws {
    #expect(MediaArtworkImage.decode(nil) == nil)
    #expect(MediaArtworkImage.decode(Data([1, 2, 3])) == nil)
    #expect(MediaArtworkImage.decode(Data(repeating: 0, count: 512 * 1024 + 1)) == nil)
    let wide = try artworkFixture(width: 513, height: 1, type: "public.png")
    #expect(wide.count < 512 * 1024)
    #expect(MediaArtworkImage.decode(wide) == nil)
    let valid = try artworkFixture(width: 512, height: 512, type: "public.png")
    #expect(MediaArtworkImage.decode(valid) != nil)
    #expect(MediaArtworkImage.decode(valid.prefix(20)) == nil)
}

private func artworkFixture(width: Int, height: Int, type: String) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.18, green: 0.55, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(encoded, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return encoded as Data
}
