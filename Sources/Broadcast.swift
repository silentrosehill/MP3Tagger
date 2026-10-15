import AppKit
import ImageIO

/// Tells other apps on this Mac (KeyForge) what's playing: the cover's main colors, title and play state.
/// A local distributed notification; nothing leaves the Mac.
@MainActor
enum NowPlayingBroadcast {
    static let name = Notification.Name("local.mp3tagger.nowPlaying")
    static let request = Notification.Name("local.keyforge.requestNowPlaying")
    private static var pending = false
    private static var cache: (key: Int, colors: [Int])?
    private static var listening = false

    /// Answers KeyForge when it starts and asks what's on.
    static func listen() {
        guard !listening else { return }
        listening = true
        DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { post() }
        }
    }

    /// Coalesced: several player changes in one run-loop turn send one notification.
    static func post() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async {
            pending = false
            let p = Player.shared
            var info: [String: Any] = ["playing": p.isPlaying && p.url != nil, "title": p.url == nil ? "" : p.nowTitle]
            if p.url != nil, let cover = p.nowCover { info["colors"] = palette(cover) }
            DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
        }
    }

    /// Up to 3 vivid, different colors from the cover (0xRRGGBB), most prominent first.
    static func palette(_ data: Data) -> [Int] {
        let key = data.hashValue ^ data.count
        if let c = cache, c.key == key { return c.colors }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary)
        else { return [] }
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: n, height: n))
        // 24 hue buckets, weighted toward vivid, bright pixels
        let buckets = 24
        var score = [Double](repeating: 0, count: buckets)
        var sum = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: buckets)
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            guard mx > 0.15, d > 0.12 else { continue }
            var h: Double
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h = (h / 6 + 1).truncatingRemainder(dividingBy: 1)
            let w = (d / mx) * (d / mx) * mx
            let k = min(Int(h * Double(buckets)), buckets - 1)
            score[k] += w
            sum[k].r += r * w; sum[k].g += g * w; sum[k].b += b * w
        }
        var picked: [Int] = []
        var used = Set<Int>()
        for _ in 0..<3 {
            guard let best = (0..<buckets).filter({ k in !used.contains(k) && score[k] > 0 }).max(by: { score[$0] < score[$1] }),
                  score[best] > 0.4 else { break }
            for dk in -2...2 { used.insert((best + dk + buckets) % buckets) }   // keep the colors apart
            let w = score[best]
            var r = sum[best].r / w, g = sum[best].g / w, b = sum[best].b / w
            let m = max(r, g, b, 0.01)                                          // full brightness for LEDs
            r /= m; g /= m; b /= m
            picked.append(Int(r * 255) << 16 | Int(g * 255) << 8 | Int(b * 255))
        }
        if picked.isEmpty { picked = [0xFFFFFF] }                               // black & white covers → white
        cache = (key, picked)
        return picked
    }
}
