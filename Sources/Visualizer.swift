import SwiftUI
import AVFoundation
import Accelerate

/// The song's frequency bands over time, measured once when it starts playing, so the mini player's
/// bars move with the actual music (bass on the left, treble on the right).
struct Spectrum: Sendable {
    static let fps = 30.0
    static let bands = 6
    /// Band edges in Hz: sub/bass, low mids, mids, upper mids, presence, air.
    private static let edges: [Double] = [30, 110, 300, 850, 2_200, 5_500, 14_000]

    /// `frames × bands` levels, 0…255.
    let levels: [UInt8]
    var frameCount: Int { levels.count / Self.bands }

    /// Level of `band` at time `t`, 0…1, blended between frames so the bars glide.
    func level(_ band: Int, at t: Double) -> Double {
        guard frameCount > 1 else { return 0 }
        let x = max(0, t * Self.fps)
        let i = min(Int(x), frameCount - 2)
        let f = min(x - Double(i), 1)
        let a = Double(levels[i * Self.bands + band]), b = Double(levels[(i + 1) * Self.bands + band])
        return (a + (b - a) * f) / 255
    }

    /// Decodes the file and runs an FFT every 1/30 s (2048-sample Hann window, mono).
    static func analyze(_ url: URL) throws -> Spectrum {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let channels = Int(format.channelCount)
        let n = 2048, log2n = vDSP_Length(11)
        let hop = max(1, Int(sr / fps))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { throw CocoaError(.fileReadCorruptFile) }

        // Mono mix of the whole song (a few minutes of Float is fine: ~50 MB at most for long tracks).
        var mono = [Float]()
        mono.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: buf.frameCapacity)
            let len = Int(buf.frameLength)
            if len == 0 { break }
            guard let ch = buf.floatChannelData else { break }
            var mix = [Float](UnsafeBufferPointer(start: ch[0], count: len))
            for c in 1..<max(channels, 1) { vDSP.add(mix, UnsafeBufferPointer(start: ch[c], count: len), result: &mix) }
            if channels > 1 { vDSP.multiply(1 / Float(channels), mix, result: &mix) }
            mono += mix
        }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let binHz = sr / Double(n)
        let bandBins: [Range<Int>] = (0..<bands).map { b in
            let lo = max(1, Int(edges[b] / binHz)), hi = min(n / 2, max(lo + 1, Int(edges[b + 1] / binHz)))
            return lo..<hi
        }
        let frames = max(0, (mono.count - n) / hop + 1)
        var db = [Float](repeating: -120, count: frames * bands)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        var windowed = [Float](repeating: 0, count: n)

        for f in 0..<frames {
            mono.withUnsafeBufferPointer { p in
                vDSP.multiply(UnsafeBufferPointer(rebasing: p[(f * hop)..<(f * hop + n)]), window, result: &windowed)
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    vDSP.squareMagnitudes(split, result: &mags)
                }
            }
            for b in 0..<bands {
                let r = bandBins[b]
                let energy = mags[r].reduce(0, +) / Float(r.count)
                db[f * bands + b] = 10 * log10(energy + 1e-12)
            }
        }

        // Each bar gets its own range (quiet floor → loud peak over the song), so hi-hats move as much as kicks.
        var levels = [UInt8](repeating: 0, count: frames * bands)
        for b in 0..<bands {
            var column = stride(from: b, to: db.count, by: bands).map { db[$0] }
            guard !column.isEmpty else { continue }
            column.sort()
            let floor = column[Int(Double(column.count - 1) * 0.15)]
            let peak = column[Int(Double(column.count - 1) * 0.985)]
            let span = max(peak - floor, 6)
            for f in 0..<frames {
                let v = min(max((db[f * bands + b] - floor) / span, 0), 1)
                levels[f * bands + b] = UInt8(pow(v, 1.4) * 255)      // a little curve: calm parts stay low, hits jump
            }
        }
        return Spectrum(levels: levels)
    }
}

/// Spectrum and bar colours for the song that's playing.
@MainActor
final class VisualizerModel: ObservableObject {
    static let shared = VisualizerModel()
    @Published private(set) var spectrum: Spectrum?
    @Published private(set) var colors: [Color] = [AppTheme.purpleDefault.pink, AppTheme.purpleDefault.purple]
    private var current: URL?
    private var cache: [URL: Spectrum] = [:]

    /// Called by the player when a new song starts.
    func load(_ url: URL, cover: Data?) {
        guard url != current else { return }
        current = url
        let known = cache[url]
        spectrum = known
        let fallback = [AppTheme.purpleDefault.pink, AppTheme.purpleDefault.purple]
        Task.detached(priority: .utility) {
            let t = cover.flatMap { AppTheme.fromCover($0) }
            let spec = known == nil ? try? Spectrum.analyze(url) : nil
            await MainActor.run {
                guard self.current == url else { return }      // skipped to another song meanwhile
                self.colors = t.map { [$0.pink, $0.purple] } ?? fallback
                if let spec {
                    if self.cache.count > 20 { self.cache.removeAll() }
                    self.cache[url] = spec
                    self.spectrum = spec
                }
            }
        }
    }
}

/// Dynamic Island-style bars: they dance to the music while playing and settle into dots when paused.
struct AudioBars: View {
    @ObservedObject private var model = VisualizerModel.shared
    let playing: Bool
    var height: CGFloat = 22
    private let barWidth: CGFloat = 3.5
    private let gap: CGFloat = 3
    private let order = [2, 0, 1, 3, 5, 4]   // mix the bands a little, like the iPhone's, instead of a strict low→high ramp

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !playing)) { _ in
            let t = Player.shared.currentTime
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<Spectrum.bands, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: model.colors, startPoint: .top, endPoint: .bottom))
                        .frame(width: barWidth, height: barHeight(i, t))
                }
            }
            .frame(height: height)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: playing)
        .shadow(color: (model.colors.first ?? .clear).opacity(playing ? 0.55 : 0), radius: 4)
        .accessibilityHidden(true)
    }

    private func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        guard playing else { return barWidth }                          // paused: a row of dots
        let v: Double
        if let s = model.spectrum {
            v = s.level(order[i], at: t)
        } else {
            // still measuring the song (well under a second): a soft idle wave
            v = 0.25 + 0.2 * sin(t * 6 + Double(i) * 1.1)
        }
        return barWidth + (height - barWidth) * CGFloat(v)
    }
}
