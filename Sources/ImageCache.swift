import AppKit
import ImageIO

/// Decoded, downsized cover images, reused across redraws. Decoding a full 1000×1000 JPEG for a
/// 32 pt row costs ~6 ms per redraw; a cached thumbnail costs ~0.01 ms.
enum CoverImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        return c
    }()

    /// `points` is the on-screen size; the thumbnail is made at 2× for Retina.
    static func image(for data: Data, points: CGFloat) -> NSImage? {
        let px = max(Int(points * 2), 16)
        let key = "\(data.hashValue)|\(data.count)|\(px)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: px] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        cache.setObject(img, forKey: key)
        return img
    }
}
