import Foundation

/// Minimal ID3 tag reader (v2.2/2.3/2.4) and writer (always writes v2.3,
/// which is the version Spotify's local-files importer handles best).
struct ID3Tag {
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var year = ""
    var track = ""
    var genre = ""
    var cover: Data?            // JPEG or PNG bytes
    var coverMime = "image/jpeg"
    /// Total lossless volume change applied by MP3 Tagger, in 1.5 dB steps (stored as TXXX "MP3TAGGER_GAIN").
    var gainSteps = 0

    /// Frames from an existing v2.3 tag that we don't edit; kept as-is on save.
    var otherFrames: [(id: String, body: Data)] = []

    static let editedIDs: Set<String> = ["TIT2", "TPE1", "TALB", "TPE2", "TYER", "TDRC", "TRCK", "TCON", "APIC"]
}

enum ID3Error: LocalizedError {
    case unreadable
    var errorDescription: String? { "Could not read the file." }
}

enum ID3 {
    // MARK: - Reading

    static func read(url: URL) throws -> ID3Tag {
        let data = try Data(contentsOf: url)
        var tag = ID3Tag()
        guard let (major, flags, size) = header(data) else {
            readV1(data, into: &tag)
            return tag
        }
        var body = Data(data[10..<min(10 + size, data.count)])
        if flags & 0x80 != 0 && major < 4 { body = deunsync(body) }
        var pos = 0
        if flags & 0x40 != 0, major == 3, body.count >= 4 {  // extended header
            pos = Int(be32(body, 0)) + 4
        } else if flags & 0x40 != 0, major == 4, body.count >= 4 {
            pos = Int(syncsafe(body, 0))
        }

        let idLen = major == 2 ? 3 : 4
        let hdrLen = major == 2 ? 6 : 10
        while pos + hdrLen <= body.count {
            let idBytes = body[pos..<pos + idLen]
            guard idBytes.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else { break }
            let id = String(decoding: idBytes, as: UTF8.self)
            let fsize: Int
            switch major {
            case 2: fsize = Int(body[pos + 3]) << 16 | Int(body[pos + 4]) << 8 | Int(body[pos + 5])
            case 3: fsize = Int(be32(body, pos + 4))
            default: fsize = Int(syncsafe(body, pos + 4))
            }
            let start = pos + hdrLen
            guard fsize > 0, start + fsize <= body.count else { break }
            var fbody = Data(body[start..<start + fsize])
            if major == 4, body[pos + 9] & 0x02 != 0 { fbody = deunsync(fbody) }
            pos = start + fsize

            let key = major == 2 ? v22Map[id] ?? id : id
            switch key {
            case "TIT2": tag.title = text(fbody)
            case "TPE1": tag.artist = text(fbody)
            case "TALB": tag.album = text(fbody)
            case "TPE2": tag.albumArtist = text(fbody)
            case "TYER", "TDRC": if tag.year.isEmpty { tag.year = text(fbody) }
            case "TRCK": tag.track = text(fbody)
            case "TCON": tag.genre = cleanGenre(text(fbody))
            case "TXXX" where Self.txxx(fbody)?.0 == "MP3TAGGER_GAIN":
                tag.gainSteps = Int(Self.txxx(fbody)?.1 ?? "") ?? 0
            case "APIC", "PIC":
                if let (mime, img, type) = picture(fbody, v22: major == 2), tag.cover == nil || type == 3 {
                    tag.cover = img
                    tag.coverMime = mime
                }
            default:
                if major == 3 { tag.otherFrames.append((id, fbody)) }
            }
        }
        return tag
    }

    private static let v22Map = ["TT2": "TIT2", "TP1": "TPE1", "TAL": "TALB", "TP2": "TPE2",
                                 "TYE": "TYER", "TRK": "TRCK", "TCO": "TCON", "PIC": "PIC"]

    private static func header(_ d: Data) -> (UInt8, UInt8, Int)? {
        guard d.count >= 10, d[0] == 0x49, d[1] == 0x44, d[2] == 0x33 else { return nil }
        return (d[3], d[5], Int(syncsafe(d, 6)))
    }

    private static func readV1(_ d: Data, into tag: inout ID3Tag) {
        guard d.count >= 128 else { return }
        let t = d.suffix(128)
        guard t.starts(with: [0x54, 0x41, 0x47]) else { return }
        func field(_ o: Int, _ l: Int) -> String {
            let s = t.index(t.startIndex, offsetBy: o)
            let bytes = t[s..<t.index(s, offsetBy: l)].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        tag.title = field(3, 30); tag.artist = field(33, 30); tag.album = field(63, 30); tag.year = field(93, 4)
    }

    /// (description, value) of a TXXX frame.
    private static func txxx(_ f: Data) -> (String, String)? {
        guard let enc = f.first else { return nil }
        let raw = Data(f.dropFirst())
        let s: String?
        switch enc {
        case 0: s = String(data: raw, encoding: .isoLatin1)
        case 1: s = String(data: raw, encoding: .utf16)
        case 2: s = String(data: raw, encoding: .utf16BigEndian)
        default: s = String(data: raw, encoding: .utf8)
        }
        let parts = (s ?? "").replacingOccurrences(of: "\u{FEFF}", with: "").split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func text(_ f: Data) -> String {
        guard let enc = f.first else { return "" }
        let raw = Data(f.dropFirst())
        var s: String?
        switch enc {
        case 0: s = String(data: raw, encoding: .isoLatin1)
        case 1: s = String(data: raw, encoding: .utf16)
        case 2: s = String(data: raw, encoding: .utf16BigEndian)
        default: s = String(data: raw, encoding: .utf8)
        }
        // Multiple values are NUL separated; keep the first, drop terminators.
        let str = (s ?? "").replacingOccurrences(of: "\u{FEFF}", with: "")
        return str.split(separator: "\0", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }

    /// "(17)" / "(17)Rock" -> "Rock" style cleanup is overkill; just strip numeric refs if text follows.
    private static func cleanGenre(_ g: String) -> String {
        if g.hasPrefix("("), let close = g.firstIndex(of: ")"), g.index(after: close) < g.endIndex {
            return String(g[g.index(after: close)...])
        }
        return g
    }

    private static func picture(_ f: Data, v22: Bool) -> (String, Data, UInt8)? {
        guard f.count > 4 else { return nil }
        let enc = f[f.startIndex]
        var i = f.startIndex + 1
        var mime = "image/jpeg"
        if v22 {
            let fmt = String(decoding: f[i..<i + 3], as: UTF8.self).uppercased()
            mime = fmt == "PNG" ? "image/png" : "image/jpeg"
            i += 3
        } else {
            guard let z = f[i...].firstIndex(of: 0) else { return nil }
            let m = String(decoding: f[i..<z], as: UTF8.self).lowercased()
            if m.contains("png") { mime = "image/png" }
            i = z + 1
        }
        guard i < f.endIndex else { return nil }
        let type = f[i]; i += 1
        // Skip description (NUL terminated; double NUL for UTF-16).
        if enc == 1 || enc == 2 {
            while i + 1 < f.endIndex, !(f[i] == 0 && f[i + 1] == 0) { i += 2 }
            i += 2
        } else {
            while i < f.endIndex, f[i] != 0 { i += 1 }
            i += 1
        }
        guard i < f.endIndex else { return nil }
        return (mime, Data(f[i...]), type)
    }

    // MARK: - Writing

    /// Writes `tag` onto the audio of `source`, saving the result at `destination`
    /// (atomically, so an existing file there is only replaced once the new one is complete).
    /// `gainDelta` changes the audio's volume losslessly (1.5 dB steps) relative to `source`.
    /// Returns the total gain now recorded in the file (less than asked only if the audio had no room for it).
    @discardableResult
    static func write(_ tag: ID3Tag, from source: URL, to destination: URL, gainDelta: Int = 0) throws -> Int {
        let data = try Data(contentsOf: source)
        var audio = data
        if let (_, flags, size) = header(data) {
            var end = 10 + size + (flags & 0x10 != 0 ? 10 : 0)  // footer (v2.4)
            end = min(end, data.count)
            audio = Data(data[end...])
        }
        // Drop the old ID3v1 tag so players don't see stale info.
        if audio.count >= 128, audio.suffix(128).starts(with: [0x54, 0x41, 0x47]) {
            audio = Data(audio.dropLast(128))
        }

        let applied = Loudness.applyGain(&audio, steps: gainDelta)
        var tag = tag
        tag.gainSteps += applied - gainDelta

        var frames = Data()
        func addText(_ id: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { return }
            frames.append(frame(id, encodeText(v)))
        }
        addText("TIT2", tag.title)
        addText("TPE1", tag.artist)
        addText("TALB", tag.album)
        addText("TPE2", tag.albumArtist)
        addText("TYER", tag.year)
        addText("TRCK", tag.track)
        addText("TCON", tag.genre)
        if tag.gainSteps != 0 {
            var b = Data([0x00])
            b.append(contentsOf: Array("MP3TAGGER_GAIN".utf8)); b.append(0)
            b.append(contentsOf: Array(String(tag.gainSteps).utf8))
            frames.append(frame("TXXX", b))
        }
        if let img = tag.cover {
            var b = Data([0x00])                        // Latin-1 description
            b.append(contentsOf: Array(tag.coverMime.utf8)); b.append(0)
            b.append(0x03)                              // picture type: front cover
            b.append(0)                                 // empty description
            b.append(img)
            frames.append(frame("APIC", b))
        }
        for f in tag.otherFrames where !ID3Tag.editedIDs.contains(f.id) {
            frames.append(frame(f.id, f.body))
        }

        let padding = 1024
        var out = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        out.append(syncsafeBytes(frames.count + padding))
        out.append(frames)
        out.append(Data(count: padding))
        out.append(audio)

        try writeSafely(out, to: destination)
        return tag.gainSteps
    }

    /// True for "you don't have permission" style failures.
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError) { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(under) }
        return false
    }

    /// Prefers an atomic save (temp file + swap). Protected folders like Downloads, Desktop and Documents
    /// let the app edit a file you opened but not create that temp file next to it, so on a permission
    /// error this rewrites the file in place instead, keeping a backup in our own temp folder until it succeeds.
    static func writeSafely(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
            return
        } catch where isPermissionError(error) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                try data.write(to: url)  // create exactly the file chosen in the save panel
                return
            }
        }

        let original = try Data(contentsOf: url)
        let backup = FileManager.default.temporaryDirectory
            .appendingPathComponent("MP3Tagger-backup-\(UUID().uuidString).mp3")
        try original.write(to: backup)
        do {
            try overwrite(url, with: data)
        } catch {
            try? overwrite(url, with: original)  // put the song back the way it was
            throw error
        }
        try? FileManager.default.removeItem(at: backup)
    }

    private static func overwrite(_ url: URL, with data: Data) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: data)
        try h.synchronize()
    }

    private static func frame(_ id: String, _ body: Data) -> Data {
        var d = Data(id.utf8)
        let n = UInt32(body.count)
        d.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        d.append(contentsOf: [0, 0])
        d.append(body)
        return d
    }

    /// Latin-1 when possible (most compatible), otherwise UTF-16 with BOM.
    private static func encodeText(_ s: String) -> Data {
        if let latin = s.data(using: .isoLatin1, allowLossyConversion: false) {
            return Data([0x00]) + latin
        }
        var d = Data([0x01, 0xFF, 0xFE])
        for u in s.utf16 { d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8)) }
        return d
    }

    // MARK: - Helpers

    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    private static func syncsafe(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i] & 0x7F) << 21 | UInt32(d[i + 1] & 0x7F) << 14 | UInt32(d[i + 2] & 0x7F) << 7 | UInt32(d[i + 3] & 0x7F)
    }

    private static func syncsafeBytes(_ n: Int) -> Data {
        Data([UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)])
    }

    private static func deunsync(_ d: Data) -> Data {
        var out = Data(capacity: d.count)
        var prevFF = false
        for b in d {
            if prevFF && b == 0x00 { prevFF = false; continue }
            out.append(b)
            prevFF = b == 0xFF
        }
        return out
    }
}
