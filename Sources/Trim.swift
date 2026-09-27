import SwiftUI

/// Lossless MP3 trimming: whole frames (~26 ms each) are cut from the start and end, nothing is re-encoded.
/// The Xing/Info header (length, seek table) and LAME tag (gapless info, checksums) are updated to match.
enum MP3Trim {
    struct Frame { let offset: Int; let length: Int }
    struct Layout {
        var frames: [Frame] = []          // audio frames
        var info: Frame?                  // Xing/Info header frame, if any
        var infoTagAt = 0                 // offset of "Xing"/"Info" inside the audio data
        var samplesPerFrame = 1152
        var sampleRate = 44100
        var seconds: Double { Double(frames.count * samplesPerFrame) / Double(sampleRate) }
    }

    /// Walks the frames of `audio` (the MP3 data after the ID3v2 tag).
    static func layout(_ audio: Data) -> Layout {
        let br1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let br2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let sr: [Int: [Int]] = [3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]]
        var out = Layout()
        audio.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let b = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
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
                guard len > 4, i + len <= n else { break }
                let next = i + len
                if next + 4 <= n {   // only trust a header followed by another matching one
                    let ok = b[next] == 0xFF && b[next + 1] & 0xE0 == 0xE0 && b[next + 1] >> 3 & 3 == b[i + 1] >> 3 & 3
                        && b[next + 1] >> 1 & 3 == 1 && b[next + 2] >> 2 & 3 == b[i + 2] >> 2 & 3
                    guard ok else { i += 1; continue }
                }
                let sideLen = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
                let tagAt = i + 4 + (crc ? 2 : 0) + sideLen
                let isInfo = out.frames.isEmpty && out.info == nil && tagAt + 4 <= n
                    && (memcmp(b + tagAt, "Xing", 4) == 0 || memcmp(b + tagAt, "Info", 4) == 0)
                if isInfo {
                    out.info = Frame(offset: i, length: len)
                    out.infoTagAt = tagAt
                } else {
                    if out.frames.isEmpty {
                        out.samplesPerFrame = mpeg1 ? 1152 : 576
                        out.sampleRate = rates[srIdx]
                    }
                    out.frames.append(Frame(offset: i, length: len))
                }
                i = next
            }
        }
        return out
    }

    /// Keeps the audio from `start` to `end` seconds (nil = to the end). Returns the new MP3 data.
    static func cut(_ audio: Data, start: Double, end: Double?) -> Data {
        let l = layout(audio)
        guard !l.frames.isEmpty else { return audio }
        let perSecond = Double(l.sampleRate) / Double(l.samplesPerFrame)
        let first = min(max(0, Int((start * perSecond).rounded(.down))), l.frames.count - 1)
        let last = min(l.frames.count, max(first + 1, end.map { Int(($0 * perSecond).rounded(.up)) } ?? l.frames.count))
        guard first > 0 || last < l.frames.count else { return audio }

        let kept = l.frames[first..<last]
        var music = Data()
        music.reserveCapacity(kept.reduce(0) { $0 + $1.length })
        for f in kept { music.append(audio[f.offset..<(f.offset + f.length)]) }
        // anything after the last frame (an APE tag, say) stays unless the end was cut
        let tailStart = l.frames.last.map { $0.offset + $0.length } ?? audio.count
        let tail = last == l.frames.count && tailStart < audio.count ? Data(audio[tailStart...]) : Data()

        guard let info = l.info else { return music + tail }
        var header = Data(audio[info.offset..<(info.offset + info.length)])
        rewriteInfo(&header, tagAt: l.infoTagAt - info.offset, oldFrames: l.frames, kept: first..<last,
                    music: music, trimmedStart: first > 0, trimmedEnd: last < l.frames.count)
        return header + music + tail
    }

    /// Updates the Xing/Info frame (frame count, byte count, seek table) and the LAME tag (gapless delay/padding,
    /// music length, both CRCs) for the trimmed audio.
    private static func rewriteInfo(_ h: inout Data, tagAt x: Int, oldFrames: [Frame], kept: Range<Int>,
                                    music: Data, trimmedStart: Bool, trimmedEnd: Bool) {
        func u32(_ at: Int) -> Int {
            let b0 = Int(h[h.startIndex + at]), b1 = Int(h[h.startIndex + at + 1])
            let b2 = Int(h[h.startIndex + at + 2]), b3 = Int(h[h.startIndex + at + 3])
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        func put32(_ at: Int, _ v: Int) { for k in 0..<4 { h[at + k] = UInt8(truncatingIfNeeded: v >> (24 - 8 * k)) } }
        guard x + 8 <= h.count else { return }
        let flags = u32(x + 4)
        var p = x + 8
        let removedFrames = oldFrames.count - kept.count
        let removedBytes = oldFrames.reduce(0) { $0 + $1.length } - music.count
        if flags & 1 != 0, p + 4 <= h.count { put32(p, max(1, u32(p) - removedFrames)); p += 4 }
        if flags & 2 != 0, p + 4 <= h.count { put32(p, max(h.count, u32(p) - removedBytes)); p += 4 }
        if flags & 4 != 0, p + 100 <= h.count {
            // seek table: where each 1% of the song starts, as a fraction (×256) of the file
            let total = Double(h.count + music.count)
            var starts: [Int] = [], pos = h.count
            for f in oldFrames[kept] { starts.append(pos); pos += f.length }
            for i in 0..<100 {
                let idx = min(starts.count - 1, Int(Double(i) / 100 * Double(starts.count)))
                h[p + i] = UInt8(min(255, Int(Double(starts[idx]) / total * 256)))
            }
            p += 100
        }
        if flags & 8 != 0 { p += 4 }

        // LAME tag (36 bytes): encoder string at p, delay/padding at p+21, music length p+28, CRCs p+32 / p+34
        guard p + 36 <= h.count, h[p..<(p + 4)].allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }) else { return }
        var delay = Int(h[p + 21]) << 4 | Int(h[p + 22]) >> 4
        var padding = (Int(h[p + 22]) & 0x0F) << 8 | Int(h[p + 23])
        if trimmedStart { delay = 0 }       // the encoder's start-up samples were cut with the first frames
        if trimmedEnd { padding = 0 }
        h[p + 21] = UInt8(delay >> 4); h[p + 22] = UInt8((delay & 0x0F) << 4 | padding >> 8); h[p + 23] = UInt8(padding & 0xFF)
        put32(p + 28, h.count + music.count)
        let musicCRC = crc16(music)
        h[p + 32] = UInt8(musicCRC >> 8); h[p + 33] = UInt8(musicCRC & 0xFF)
        let tagCRC = crc16(h[0..<(p + 34)])
        h[p + 34] = UInt8(tagCRC >> 8); h[p + 35] = UInt8(tagCRC & 0xFF)
    }

    /// CRC-16/ARC, the one LAME uses for its tag and music checksums.
    static func crc16<D: DataProtocol>(_ d: D) -> UInt16 {
        var c: UInt16 = 0
        for byte in d {
            c ^= UInt16(byte)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
        }
        return c
    }
}

/// Editor card: cut the talking intro/outro. Applied (losslessly) when you save.
struct TrimCard: View {
    @ObservedObject var file: TrackFile
    @ObservedObject private var player = Player.shared
    @ObservedObject private var progress = PlayerProgress.shared
    @Environment(\.appTheme) private var theme
    @StateObject private var length = TrimLength()

    private var total: Double { length.seconds }
    private var end: Double { file.trimEnd ?? total }
    private var loaded: Bool { player.url == file.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Trim", systemImage: "scissors").font(.headline)
                Spacer()
                if file.trimStart > 0 || file.trimEnd != nil {
                    Button { file.trimStart = 0; file.trimEnd = nil; refreshDirty() } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
                        .labelStyle(.iconOnly).buttonStyle(.purpleGlassIcon(26)).help("Keep the whole song")
                }
            }
            // kept part of the song
            GeometryReader { g in
                let w = g.size.width, a = total > 0 ? file.trimStart / total : 0, b = total > 0 ? end / total : 1
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [theme.pink, theme.purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, w * (b - a))).offset(x: w * a)
                    if loaded, total > 0 {
                        Capsule().fill(.white).frame(width: 2, height: 12).offset(x: w * min(progress.current / total, 1) - 1)
                    }
                }
            }
            .frame(height: 8)
            row("Start", value: file.trimStart, set: { file.trimStart = min(max(0, $0), end - 1) })
            row("End", value: end, set: { v in let e = max(min(v, total), file.trimStart + 1); file.trimEnd = e >= total - 0.01 ? nil : e })
            Text("New length \(PlayerProgressFormat.string(max(0, end - file.trimStart))) of \(PlayerProgressFormat.string(total)). Cuts whole MP3 frames, no re-encoding. Applies when you save; use Save As to keep the original.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        .onAppear { length.measure(file.url) }
        .onChange(of: file.url) { _, u in length.measure(u) }
    }

    private func row(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 36, alignment: .leading)
            Button { set(value - 0.5); refreshDirty() } label: { Image(systemName: "minus") }
                .buttonStyle(.purpleGlassIcon(22)).help("0.5 s earlier")
            Text(String(format: "%@.%d", PlayerProgressFormat.string(value.rounded(.down)), Int((value * 10).rounded(.down)) % 10))
                .font(.callout.monospacedDigit()).frame(width: 52)
            Button { set(value + 0.5); refreshDirty() } label: { Image(systemName: "plus") }
                .buttonStyle(.purpleGlassIcon(22)).help("0.5 s later")
            Spacer(minLength: 4)
            Button("Here") { set(progress.current); refreshDirty() }
                .buttonStyle(.purpleGlass).controlSize(.small)
                .disabled(!loaded)
                .help(loaded ? "Use the current playback position" : "Play this song first, then click at the right moment")
            Button { preview(from: label == "Start" ? value : max(file.trimStart, value - 4)) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.purpleGlassIcon(22))
                .help(label == "Start" ? "Play from the new start" : "Play the last 4 seconds before the new end")
        }
    }

    private func preview(from t: Double) {
        if !loaded { player.toggle(file.url, from: .files) }
        else if !player.isPlaying { player.playPause() }
        player.seek(to: t)
    }

    private func refreshDirty() { if file.trimStart > 0 || file.trimEnd != nil { file.dirty = true } }
}

/// The song's length, read in the background.
final class TrimLength: ObservableObject {
    @Published var seconds: Double = 0
    func measure(_ url: URL) {
        Task.detached(priority: .utility) {
            let s = (try? Data(contentsOf: url)).map { data -> Double in
                var audio = data
                if data.count > 10, data.prefix(3) == Data("ID3".utf8) {
                    let size = Int(data[6]) << 21 | Int(data[7]) << 14 | Int(data[8]) << 7 | Int(data[9])
                    audio = Data(data[min(data.count, 10 + size)...])
                }
                return MP3Trim.layout(audio).seconds
            } ?? 0
            await MainActor.run { self.seconds = s }
        }
    }
}
