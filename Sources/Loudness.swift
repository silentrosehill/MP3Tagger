import Foundation
import AVFoundation
import Accelerate

/// Loudness measurement (ITU-R BS.1770 / EBU R128 integrated loudness, in LUFS) and
/// lossless MP3 volume change in the style of MP3Gain.
enum Loudness {
    /// Spotify's default playback loudness.
    static let spotifyTarget = -14.0
    /// One MP3 global-gain step.
    static let stepDB = 1.5
    /// Keep sample peaks at least this far below full scale when boosting.
    static let peakCeilingDB = -0.5

    struct Result {
        let lufs: Double
        /// Highest absolute sample value (1.0 = full scale).
        let peak: Double
        var peakDB: Double { peak > 0 ? 20 * log10(peak) : -120 }
    }

    // MARK: Measuring

    /// Decodes the file and measures integrated loudness and sample peak.
    static func measure(_ url: URL) throws -> Result {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let meter = Meter(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw CocoaError(.fileReadCorruptFile) }
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            meter.feed(buf)
        }
        return meter.result()
    }

    /// Cached `measure`: results are remembered per file version (path + size + modification date),
    /// so reopening a song is instant; saving changes the date, which triggers a fresh measurement.
    static func measureCached(_ url: URL) throws -> Result {
        let key = cacheKey(url)
        if let key, let hit = cache.value(for: key) { return hit }
        let r = try measure(url)
        if let key { cache.set(r, for: key) }
        return r
    }

    private static func cacheKey(_ url: URL) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        return "\(url.standardizedFileURL.path)|\(size)|\(date.timeIntervalSince1970)"
    }

    private final class ResultCache: @unchecked Sendable {
        private var store: [String: Result] = [:]
        private let lock = NSLock()
        func value(for k: String) -> Result? { lock.lock(); defer { lock.unlock() }; return store[k] }
        func set(_ r: Result, for k: String) { lock.lock(); store[k] = r; lock.unlock() }
    }
    private static let cache = ResultCache()

    /// Streaming BS.1770 meter: K-weighting filter, 400 ms blocks with 75% overlap, absolute + relative gating.
    /// Filtering and sums run through Accelerate (vDSP), a whole chunk at a time.
    final class Meter {
        private let channels: Int
        private let segmentLength: Int          // 100 ms
        private var segmentPos = 0
        private var segmentSum: [Double]
        private var segments: [[Double]] = []    // per-segment mean square, per channel
        private var peak: Float = 0
        private let setup: vDSP_biquad_Setup
        private var delays: [[Float]]            // biquad state per channel
        private var filtered: [Float] = []

        init(sampleRate fs: Double, channels: Int) {
            self.channels = max(channels, 1)
            segmentLength = max(Int(fs * 0.1), 1)
            segmentSum = Array(repeating: 0, count: self.channels)

            // K-weighting, exact coefficients for any sample rate (same derivation as libebur128).
            // Stage 1: high shelf (+4 dB above ~1.7 kHz), models the head.
            let f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
            let K = tan(.pi * f0 / fs)
            let Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
            let a0 = 1 + K / Q + K * K
            // Stage 2: high-pass (~38 Hz), "RLB" weighting.
            let f1 = 38.13547087602444, Q1 = 0.5003270373238773
            let K1 = tan(.pi * f1 / fs), a01 = 1 + K1 / Q1 + K1 * K1
            // vDSP biquad sections: b0, b1, b2, a1, a2
            let coeffs: [Double] = [
                (Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0,
                2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0,
                1, -2, 1,
                2 * (K1 * K1 - 1) / a01, (1 - K1 / Q1 + K1 * K1) / a01,
            ]
            setup = vDSP_biquad_CreateSetup(coeffs, 2)!
            delays = Array(repeating: Array(repeating: 0, count: 2 * 2 + 2), count: self.channels)
        }

        deinit { vDSP_biquad_DestroySetup(setup) }

        func feed(_ buf: AVAudioPCMBuffer) {
            guard let data = buf.floatChannelData else { return }
            let n = Int(buf.frameLength), nch = min(Int(buf.format.channelCount), channels)
            guard n > 0 else { return }
            if filtered.count < n * nch { filtered = Array(repeating: 0, count: n * nch) }

            filtered.withUnsafeMutableBufferPointer { out in
                for ch in 0..<nch {
                    var m: Float = 0
                    vDSP_maxmgv(data[ch], 1, &m, vDSP_Length(n))
                    peak = max(peak, m)
                    delays[ch].withUnsafeMutableBufferPointer { d in
                        vDSP_biquad(setup, d.baseAddress!, data[ch], 1, out.baseAddress! + ch * n, 1, vDSP_Length(n))
                    }
                }
                var off = 0
                while off < n {
                    let take = min(segmentLength - segmentPos, n - off)
                    for ch in 0..<nch {
                        var sq: Float = 0
                        vDSP_svesq(out.baseAddress! + ch * n + off, 1, &sq, vDSP_Length(take))
                        segmentSum[ch] += Double(sq)
                    }
                    segmentPos += take
                    off += take
                    if segmentPos == segmentLength {
                        segments.append(segmentSum.map { $0 / Double(segmentLength) })
                        segmentSum = Array(repeating: 0, count: channels)
                        segmentPos = 0
                    }
                }
            }
        }

        func result() -> Result {
            // 400 ms blocks = 4 consecutive 100 ms segments (75% overlap).
            var blocks: [Double] = []
            if segments.count >= 4 {
                for i in 0...(segments.count - 4) {
                    var z = 0.0
                    for ch in 0..<channels { z += (segments[i][ch] + segments[i + 1][ch] + segments[i + 2][ch] + segments[i + 3][ch]) / 4 }
                    blocks.append(z)
                }
            }
            func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
            let abs = blocks.filter { $0 > 0 && lufs($0) > -70 }
            guard !abs.isEmpty else { return Result(lufs: -70, peak: Double(peak)) }
            let relGate = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
            let gated = abs.filter { lufs($0) > relGate }
            let z = gated.reduce(0, +) / Double(max(gated.count, 1))
            return Result(lufs: lufs(z), peak: Double(peak))
        }
    }

    /// Gain steps (1.5 dB each) that bring `r` to Spotify's level, capped so peaks stay below the ceiling.
    static func recommendedSteps(for r: Result) -> (steps: Int, limited: Bool) {
        let wanted = Int(((spotifyTarget - r.lufs) / stepDB).rounded())
        guard wanted > 0 else { return (wanted, false) }
        let headroom = max(Int(floor((peakCeilingDB - r.peakDB) / stepDB)), 0)
        return wanted > headroom ? (headroom, true) : (wanted, false)
    }

    // MARK: Lossless gain (MP3Gain-style)

    /// Changes every Layer III granule's global_gain by up to `steps` (×1.5 dB) and returns the steps actually
    /// applied. No re-encoding. Silent granules (no coded data) are left alone, and the change is limited so no
    /// value hits 0 or 255 — so applying the opposite amount restores the file byte for byte.
    /// `audio` must start after the ID3v2 tag.
    private static let silenceFloor = 64

    @discardableResult
    static func applyGain(_ audio: inout Data, steps: Int) -> Int {
        guard steps != 0 else { return 0 }
        let br1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let br2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let sr: [Int: [Int]] = [3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]]

        return audio.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            guard let b = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            // Pass 1 finds every audible granule's gain field; pass 2 (below) changes them.
            struct Frame { let header: Int; let side: Int; let sideLen: Int; let crc: Bool; let gainBits: [Int] }
            var frames: [Frame] = []
            var minGain = 255, maxGain = 0
            let n = raw.count
            var i = 0
            while i + 4 <= n {
                guard b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 else { i += 1; continue }
                let ver = Int(b[i + 1] >> 3 & 3), layer = b[i + 1] >> 1 & 3, crc = b[i + 1] & 1 == 0
                let brIdx = Int(b[i + 2] >> 4), srIdx = Int(b[i + 2] >> 2 & 3), pad = Int(b[i + 2] >> 1 & 1)
                let mono = b[i + 3] >> 6 == 3
                guard ver != 1, layer == 1, brIdx != 0, brIdx != 15, srIdx != 3, let rates = sr[ver] else { i += 1; continue }
                let mpeg1 = ver == 3
                let len = (mpeg1 ? 144 : 72) * (mpeg1 ? br1 : br2)[brIdx] * 1000 / rates[srIdx] + pad
                let nch = mono ? 1 : 2
                let sideLen = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
                let si = i + 4 + (crc ? 2 : 0)
                guard len > 4, i + len <= n, si + sideLen <= n else { break }
                // Only trust a header that's followed by another matching frame (or the end of the audio),
                // so stray 0xFF bytes can never be mistaken for a frame and modified.
                let next = i + len
                if next + 4 <= n {
                    let ok = b[next] == 0xFF && b[next + 1] & 0xE0 == 0xE0
                        && b[next + 1] >> 3 & 3 == b[i + 1] >> 3 & 3 && b[next + 1] >> 1 & 3 == 1
                        && b[next + 2] >> 2 & 3 == b[i + 2] >> 2 & 3
                    guard ok else { i += 1; continue }
                }

                // Skip the Xing/Info header frame (no audio).
                let tagAt = si + sideLen
                let isInfo = tagAt + 4 <= n && (memcmp(b + tagAt, "Xing", 4) == 0 || memcmp(b + tagAt, "Info", 4) == 0)
                if !isInfo {
                    var offsets: [Int] = []
                    if mpeg1 {
                        let start = 9 + (mono ? 5 : 3) + 4 * nch
                        for gr in 0..<2 { for ch in 0..<nch { offsets.append(start + (gr * nch + ch) * 59 + 21) } }
                    } else {
                        let start = 8 + (mono ? 1 : 2)
                        for ch in 0..<nch { offsets.append(start + ch * 63 + 21) }
                    }
                    // Leave silent granules alone: no coded data (part2_3_length, the 12 bits 21 before
                    // global_gain, is 0) or a gain below the silence floor (inaudible, < −219 dB).
                    let audible = offsets.filter { readBits(b + si, $0 - 21, 12) > 0 && readBits(b + si, $0, 8) >= silenceFloor }
                    for bit in audible {
                        let g = Int(readBits(b + si, bit, 8))
                        minGain = min(minGain, g); maxGain = max(maxGain, g)
                    }
                    if !audible.isEmpty { frames.append(Frame(header: i, side: si, sideLen: sideLen, crc: crc, gainBits: audible)) }
                }
                i += len
            }

            guard !frames.isEmpty else { return 0 }
            // Changed granules must stay within silenceFloor...255, so the same granules are chosen next time
            // and the opposite change restores every byte.
            let applied = steps < 0 ? max(steps, min(0, silenceFloor - minGain)) : min(steps, max(0, 255 - maxGain))
            guard applied != 0 else { return 0 }
            for f in frames {
                let si = f.side, sideLen = f.sideLen, i = f.header, crc = f.crc
                for bit in f.gainBits {
                    writeBits(b + si, bit, 8, UInt32(Int(readBits(b + si, bit, 8)) + applied))
                }
                do {
                    guard crc else { continue }  // CRC-16 covers header bytes 2–3 and the side info
                        var c: UInt16 = 0xFFFF
                        func feed(_ byte: UInt8) {
                            for k in (0..<8).reversed() {
                                let bitIn = (UInt16(byte) >> UInt16(k)) & 1
                                let top = (c >> 15) & 1
                                c <<= 1
                                if top ^ bitIn == 1 { c ^= 0x8005 }
                            }
                        }
                        feed(b[i + 2]); feed(b[i + 3])
                        for k in 0..<sideLen { feed(b[si + k]) }
                        b[i + 4] = UInt8(c >> 8); b[i + 5] = UInt8(c & 0xFF)
                }
            }
            return applied
        }
    }

    private static func readBits(_ p: UnsafeMutablePointer<UInt8>, _ start: Int, _ count: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<count {
            let pos = start + k
            v = v << 1 | UInt32(p[pos >> 3] >> (7 - UInt8(pos & 7)) & 1)
        }
        return v
    }

    private static func writeBits(_ p: UnsafeMutablePointer<UInt8>, _ start: Int, _ count: Int, _ value: UInt32) {
        for k in 0..<count {
            let pos = start + k
            let bit = UInt8(value >> UInt32(count - 1 - k) & 1)
            let mask = UInt8(1) << (7 - UInt8(pos & 7))
            p[pos >> 3] = bit == 1 ? p[pos >> 3] | mask : p[pos >> 3] & ~mask
        }
    }
}

// MARK: - Editor card

import SwiftUI

@MainActor
final class LoudnessAnalysis: ObservableObject {
    @Published var result: Loudness.Result?
    @Published var measuring = false
    @Published var failed = false
    @Published var limited = false
    private var generation = 0

    func analyze(_ url: URL) {
        generation += 1
        let gen = generation
        measuring = true
        failed = false
        Task.detached(priority: .userInitiated) {
            let r = try? Loudness.measureCached(url)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.result = r
                self.failed = r == nil
                self.measuring = false
            }
        }
    }
}

/// Shows the song's loudness against Spotify's level and lets you boost it losslessly (applied on Save).
struct LoudnessCard: View {
    @ObservedObject var file: TrackFile
    @StateObject private var analysis = LoudnessAnalysis()
    @Environment(\.appTheme) private var theme

    private let low = -30.0, high = -6.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Loudness", systemImage: "speaker.wave.3.fill").font(.headline)
                Spacer()
                if analysis.measuring { ProgressView().controlSize(.small) }
            }

            if let r = analysis.result {
                let pending = Double(file.tag.gainSteps - file.savedGain) * Loudness.stepDB
                let now = r.lufs + pending
                meter(now)
                Text("\(fmt(now)) LUFS\(pending != 0 ? " after saving" : "") · Spotify plays at −14 LUFS")
                    .font(.callout).foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Match Spotify") { match(r) }
                        .buttonStyle(.purpleGlassProminent)
                        .help("Set the boost that brings this song to Spotify's loudness")
                    Button { change(-1) } label: { Label("Quieter", systemImage: "minus") }
                        .help("−1.5 dB")
                    Text(boostText).font(.callout.monospacedDigit()).frame(minWidth: 70)
                    Button { change(+1) } label: { Label("Louder", systemImage: "plus") }
                        .help("+1.5 dB")
                    Button { reset() } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
                        .help("Back to the original volume")
                        .disabled(file.tag.gainSteps == 0)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.purpleGlassIcon(30))

                if r.peakDB + pending > Loudness.peakCeilingDB + 0.01 && pending > 0 {
                    Label("This much boost may distort the loudest parts.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if analysis.limited {
                    Label("Boost limited so the loudest parts don't distort.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Lossless: the audio isn't re-encoded, and Reset restores the original exactly. Applies when you save.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if analysis.failed {
                Text("Couldn't read this song's audio.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Measuring…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background {
            StyledPanel(cornerRadius: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [theme.purple.opacity(0.12), theme.indigo.opacity(0.14)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.rim.opacity(0.6), lineWidth: 1))
            }
        }
        .onAppear { analysis.analyze(file.url) }
        .onChange(of: file.savedGain) { _, _ in analysis.analyze(file.url) }   // re-measure after saving
        .onChange(of: file.url) { _, new in analysis.analyze(new) }
    }

    private var boostText: String {
        let db = Double(file.tag.gainSteps) * Loudness.stepDB
        return db == 0 ? "Original" : (db > 0 ? "+" : "−") + String(format: "%.1f dB", abs(db))
    }

    private func fmt(_ v: Double) -> String { (v < 0 ? "−" : "") + String(format: "%.1f", abs(v)) }

    private func meter(_ value: Double) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let x = { (v: Double) -> CGFloat in CGFloat((min(max(v, low), high) - low) / (high - low)) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(LinearGradient(colors: [theme.indigo, theme.purple, theme.pink],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(x(value), 8))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: value)
                Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: 16).offset(x: x(Loudness.spotifyTarget) - 1)
                Text("Spotify").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .offset(x: x(Loudness.spotifyTarget) - 16, y: -15)
            }
        }
        .frame(height: 10)
        .padding(.top, 12)
    }

    private func match(_ r: Loudness.Result) {
        let rec = Loudness.recommendedSteps(for: r)
        analysis.limited = rec.limited
        set(file.savedGain + rec.steps)
    }

    private func change(_ d: Int) { analysis.limited = false; set(file.tag.gainSteps + d) }
    private func reset() { analysis.limited = false; set(0) }

    private func set(_ steps: Int) {
        let clamped = min(max(steps, -20), 20)  // ±30 dB
        guard clamped != file.tag.gainSteps else { return }
        file.tag.gainSteps = clamped
        file.dirty = true
    }
}
