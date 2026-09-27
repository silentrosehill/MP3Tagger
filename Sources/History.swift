import SwiftUI
import AppKit

/// One saved song. Saving the same file again updates its entry instead of adding a new one.
struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var path: String
    var title: String
    var artist: String
    var album: String
    var lastSaved: Date
    var saveCount: Int
    var thumb: Data?

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var displayTitle: String { title.isEmpty ? url.deletingPathExtension().lastPathComponent : title }
}

/// Songs you've saved (not just opened), newest first. Stored in ~/Library/Application Support/MP3 Tagger.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL = {
        // MP3TAGGER_HISTORY lets tests use a throwaway file instead of the real history.
        if let override = ProcessInfo.processInfo.environment["MP3TAGGER_HISTORY"] { return URL(fileURLWithPath: override) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MP3 Tagger", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    func record(url: URL, tag: ID3Tag) {
        var entry = entries.first { $0.path == url.path }
            ?? HistoryEntry(path: url.path, title: "", artist: "", album: "", lastSaved: .now, saveCount: 0)
        entry.title = tag.title
        entry.artist = tag.artist
        entry.album = tag.album
        entry.lastSaved = .now
        entry.saveCount += 1
        entry.thumb = tag.cover.flatMap { NSImage(data: $0) }.flatMap { jpegCover(from: $0, maxSide: 96) }
        entries.removeAll { $0.path == url.path }
        entries.insert(entry, at: 0)
        persist()
    }

    func remove(_ id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    var selected = false
    @StateObject private var hover = HoverState()
    var onError: (String) -> Void
    var body: some View {
        let exists = entry.exists
        HStack {
            PlayableThumb(url: entry.url, data: entry.thumb, onError: onError)
                .disabled(!exists)
            VStack(alignment: .leading) {
                MarqueeText(text: entry.displayTitle, font: .body, active: hover.on || selected)
                Text(entry.lastSaved.formatted(.relative(presentation: .named)).capitalizedFirst
                     + (entry.artist.isEmpty ? "" : " · \(entry.artist)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !exists {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("File was moved or deleted")
            }
        }
        .opacity(exists ? 1 : 0.55)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }
}

/// Loads the full-size cover from disk for the history detail view.
@MainActor
final class LiveTag: ObservableObject {
    @Published var tag: ID3Tag?
    func load(_ url: URL) {
        Task.detached {
            let t = try? ID3.read(url: url)
            await MainActor.run { self.tag = t }
        }
    }
}

struct HistoryDetail: View {
    let entry: HistoryEntry
    @ObservedObject var lib: Library
    @ObservedObject private var player = Player.shared
    @StateObject private var live = LiveTag()

    var body: some View {
        let tag = live.tag
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                CoverArt(data: tag?.cover ?? entry.thumb)
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.1), .white.opacity(0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 7)

                VStack(alignment: .leading, spacing: 6) {
                    Text(tag.map { $0.title.isEmpty ? entry.displayTitle : $0.title } ?? entry.displayTitle)
                        .font(.title2.bold())
                    Text((tag?.artist ?? entry.artist).isEmpty ? "Unknown artist" : (tag?.artist ?? entry.artist))
                        .font(.title3).foregroundStyle(.secondary)
                    if let album = tag?.album ?? Optional(entry.album), !album.isEmpty {
                        Text(album).foregroundStyle(.secondary)
                    }

                    Divider().padding(.vertical, 6)
                    Label("Last saved \(entry.lastSaved.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    Label(entry.saveCount == 1 ? "Saved once" : "Saved \(entry.saveCount) times", systemImage: "square.and.arrow.down")
                    if !entry.exists {
                        Label("File was moved or deleted", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }

                    HStack {
                        Button {
                            if let err = player.toggle(entry.url) { lib.status = err }
                        } label: {
                            Label(player.isPlaying(entry.url) ? "Pause" : "Play",
                                  systemImage: player.isPlaying(entry.url) ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.purpleGlassProminent)
                        Button("Open in Editor") { lib.openInEditor(entry.url) }.buttonStyle(.purpleGlass)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }.buttonStyle(.purpleGlass)
                    }
                    .disabled(!entry.exists)
                    .padding(.top, 10)

                    Text(entry.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).padding(.top, 4)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(24)
        }
        .onAppear {
            ThemeStore.shared.follow(cover: entry.thumb)
            if entry.exists { live.load(entry.url) }
        }
        .onChange(of: live.tag?.cover) { _, new in if let new { ThemeStore.shared.follow(cover: new) } }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
