import SwiftUI
import AppKit
import AVFoundation

/// One song from Apple's catalog (iTunes Search API, no key needed).
struct TrackMatch: Decodable, Identifiable, Equatable, Sendable {
    let trackId: Int
    let trackName: String
    let artistName: String
    let collectionName: String?
    let collectionArtistName: String?
    let releaseDate: String?
    let trackNumber: Int?
    let trackCount: Int?
    let primaryGenreName: String?
    let artworkUrl100: String?
    let trackTimeMillis: Int?

    var id: Int { trackId }
    var year: String { releaseDate.map { String($0.prefix(4)) } ?? "" }
    var seconds: Double? { trackTimeMillis.map { Double($0) / 1000 } }
    var trackText: String {
        guard let n = trackNumber else { return "" }
        return trackCount.map { "\(n)/\($0)" } ?? "\(n)"
    }
    func artwork(_ side: Int) -> URL? {
        artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "\(side)x\(side)bb")) }
    }
    var thumb: URL? { artwork(120) }
}

enum TagLookup {
    /// Top catalog matches for a title/artist, best first. `duration` (seconds) helps pick the right version.
    static func search(title: String, artist: String, duration: Double? = nil, limit: Int = 8) async -> [TrackMatch] {
        let cleanTitle = simplify(title, keepWords: true)
        let term = [primaryArtist(artist), cleanTitle].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return [] }
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: "song"),
                        URLQueryItem(name: "limit", value: "25")]
        struct Response: Decodable { let results: [TrackMatch] }
        guard let (data, _) = try? await URLSession.shared.data(from: c.url!),
              let found = try? JSONDecoder().decode(Response.self, from: data).results else { return [] }
        let ranked = found.map { ($0, score($0, title: title, artist: artist, duration: duration)) }
            .sorted { $0.1 > $1.1 }
        return Array(ranked.prefix(limit).map(\.0))
    }

    /// The best match only if it's convincing (right song and artist), else nil.
    static func best(title: String, artist: String, duration: Double? = nil) async -> TrackMatch? {
        guard let top = await search(title: title, artist: artist, duration: duration, limit: 1).first else { return nil }
        return score(top, title: title, artist: artist, duration: duration) >= 0.75 ? top : nil
    }

    /// 0…1+: title similarity dominates, artist must overlap, duration and "not a cover/karaoke" nudge.
    static func score(_ m: TrackMatch, title: String, artist: String, duration: Double?) -> Double {
        let want = simplify(title, keepWords: false), got = simplify(m.trackName, keepWords: false)
        guard !want.isEmpty, !got.isEmpty else { return 0 }
        var s: Double
        if want == got { s = 0.7 }
        else if got.hasPrefix(want) || want.hasPrefix(got) { s = 0.55 }
        else if got.contains(want) || want.contains(got) { s = 0.45 }
        else { s = 0.7 * overlap(want, got) }

        let wa = simplify(artist, keepWords: false), ga = simplify(m.artistName, keepWords: false)
        if !wa.isEmpty {
            if ga.contains(wa) || wa.contains(ga) || overlap(wa, ga) >= 0.5 { s += 0.3 } else { s -= 0.3 }
        } else { s += 0.1 }

        if let d = duration, let md = m.seconds {
            let diff = abs(d - md)
            s += diff < 4 ? 0.1 : diff < 20 ? 0.05 : diff > 90 ? -0.1 : 0
        }
        // a remix/live/sped-up version must not become the original (or the other way round)
        let versions = ["remix", "live", "slowed", "sped up", "acoustic", "instrumental", "mashup", "edit", "version", "demo"]
        let wantedText = title.lowercased(), gotText = m.trackName.lowercased()
        for v in versions where wantedText.contains(v) != gotText.contains(v) { s -= v == "version" || v == "edit" ? 0.1 : 0.35 }
        if wantedText.contains(" x ") && !gotText.contains(" x ") { s -= 0.35 }      // "Mercy x Feel Good" mashups

        let junk = ["karaoke", "tribute", "cover", "instrumental", "made famous", "originally performed"]
        let text = (m.trackName + " " + m.artistName + " " + (m.collectionName ?? "")).lowercased()
        if junk.contains(where: text.contains) && !title.lowercased().contains("instrumental") { s -= 0.4 }
        return s
    }

    /// Fills a tag from a catalog match (keeps the song's own loudness info and extra frames).
    static func apply(_ m: TrackMatch, to tag: inout ID3Tag, cover: Data?) {
        tag.title = m.trackName
        tag.artist = m.artistName
        if let a = m.collectionName { tag.album = cleanAlbum(a) }
        tag.albumArtist = m.collectionArtistName ?? m.artistName
        if !m.year.isEmpty { tag.year = m.year }
        if !m.trackText.isEmpty { tag.track = m.trackText }
        if let g = m.primaryGenreName { tag.genre = g }
        if let cover {
            tag.cover = cover
            tag.coverMime = "image/jpeg"
        }
    }

    /// Song length in seconds (reads only the header).
    static func duration(of url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// Looks the downloaded song up and, if there's a convincing match, rewrites its tags and cover.
    /// Returns the new title, or nil if nothing good was found (the file is then left as it was).
    static func fillOfficialTags(_ file: URL) async -> String? {
        guard var tag = try? ID3.read(url: file) else { return nil }
        let title = tag.title.isEmpty ? file.deletingPathExtension().lastPathComponent : tag.title
        guard let m = await best(title: title, artist: tag.artist, duration: duration(of: file)) else { return nil }
        let cover = await coverData(for: m)
        apply(m, to: &tag, cover: cover)
        guard (try? ID3.write(tag, from: file, to: file, gainDelta: 0)) != nil else { return nil }
        return tag.title
    }

    /// 1000 px JPEG of the match's artwork, ready for the tag.
    static func coverData(for m: TrackMatch) async -> Data? {
        guard let url = m.artwork(1200), let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return nil }
        return jpegCover(from: img)
    }

    // MARK: Text helpers

    /// "Runaway (Video Version) ft. Pusha T" → "runaway" (keepWords keeps casing/spaces for the search term).
    static func simplify(_ s: String, keepWords: Bool) -> String {
        var t = s
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#,                         // (anything) [anything]
                        #"\s+(ft\.?|feat\.?|featuring|with)\s+.*$"#,          // featured artists
                        #"\s+-\s+(remaster(ed)?|single|radio edit).*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        if keepWords { return t.trimmingCharacters(in: .whitespaces) }
        return t.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// "Kanye West, Travis Scott" / "Kanye West & Jay-Z" → "Kanye West"
    static func primaryArtist(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .replacingOccurrences(of: #"\s+(x|feat\.?|ft\.?)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces) ?? s
    }

    /// "Graduation - Single" → "Graduation"
    static func cleanAlbum(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+-\s+(Single|EP)$"#, with: "", options: .regularExpression)
    }

    private static func overlap(_ a: String, _ b: String) -> Double {
        // character bigram overlap (Dice coefficient) on already-simplified strings
        func grams(_ s: String) -> Set<String> {
            let c = Array(s); guard c.count > 1 else { return [s] }
            return Set((0..<(c.count - 1)).map { String(c[$0...($0 + 1)]) })
        }
        let ga = grams(a), gb = grams(b)
        return 2 * Double(ga.intersection(gb).count) / Double(ga.count + gb.count)
    }
}

/// Editor sheet: pick the right song from Apple's catalog to fill in all the tags and the cover.
@MainActor
final class TagLookupModel: ObservableObject {
    @Published var results: [TrackMatch] = []
    @Published var loading = false
    @Published var applying: Int?
    @Published var query = ""

    func run(title: String, artist: String, duration: Double?) {
        loading = true
        results = []
        Task {
            // a free-typed query goes in as the title with no artist
            results = await TagLookup.search(title: title, artist: artist, duration: duration)
            loading = false
        }
    }
}

struct TagLookupSheet: View {
    @ObservedObject var file: TrackFile
    let onDone: (String?) -> Void
    @StateObject private var model = TagLookupModel()
    @Environment(\.appTheme) private var theme

    private var duration: Double? { TagLookup.duration(of: file.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Official Tags").font(.title3.bold())
                Spacer()
                Button("Cancel") { onDone(nil) }.buttonStyle(.purpleGlass).keyboardShortcut(.cancelAction)
            }
            Text("Pick the right song from Apple's catalog. Title, artist, album, year, track, genre and a high-res cover get filled in (you can still edit them before saving).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Song and artist", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.run(title: model.query, artist: "", duration: duration) }
                Button("Search") { model.run(title: model.query, artist: "", duration: duration) }
                    .buttonStyle(.purpleGlassProminent)
            }
            Group {
                if model.loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if model.results.isEmpty {
                    Text("No matches. Try other words.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.results) { m in row(m) }
                        }
                    }
                }
            }
            .frame(height: 340)
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            let t = file.tag
            let title = t.title.isEmpty ? file.url.deletingPathExtension().lastPathComponent : t.title
            model.query = [TagLookup.primaryArtist(t.artist), TagLookup.simplify(title, keepWords: true)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            model.loading = true
            Task {
                model.results = await TagLookup.search(title: title, artist: t.artist, duration: duration)
                model.loading = false
            }
        }
    }

    private func row(_ m: TrackMatch) -> some View {
        Button {
            model.applying = m.id
            Task {
                let cover = await TagLookup.coverData(for: m)
                TagLookup.apply(m, to: &file.tag, cover: cover)
                file.dirty = true
                model.applying = nil
                onDone("Filled in from Apple Music: \(m.trackName) · \(m.collectionName.map(TagLookup.cleanAlbum) ?? "")")
            }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: m.thumb) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.quaternary) }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.trackName).font(.body.weight(.semibold)).lineLimit(1)
                    Text([m.artistName, m.collectionName.map(TagLookup.cleanAlbum), m.year.isEmpty ? nil : m.year]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.applying == m.id { ProgressView().controlSize(.small) }
                else if let s = m.seconds { Text(PlayerProgressFormat.string(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.applying != nil)
    }
}

/// m:ss formatting usable off the main actor.
enum PlayerProgressFormat {
    static func string(_ d: Double) -> String {
        let s = Int(d.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
