import SwiftUI
import AppKit
import AVFoundation

/// One YouTube search result.
struct FoundVideo: Identifiable, Equatable {
    let id: String          // YouTube video id
    let title: String
    let channel: String
    let duration: Double?
    let views: Int?

    var link: String { "https://www.youtube.com/watch?v=\(id)" }
    var thumbnail: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }

    var durationText: String? {
        guard let d = duration else { return nil }
        let s = Int(d.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    var viewsText: String? {
        guard let v = views else { return nil }
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB views", Double(v) / 1e9)
        case 1_000_000...: return String(format: "%.1fM views", Double(v) / 1e6)
        case 1_000...: return "\(v / 1_000)K views"
        default: return "\(v) views"
        }
    }

    /// Reads one line of `yt-dlp --flat-playlist --dump-json` output.
    init?(json line: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["id"] as? String, let title = obj["title"] as? String else { return nil }
        self.id = id
        self.title = title
        channel = (obj["channel"] as? String) ?? (obj["uploader"] as? String) ?? ""
        duration = obj["duration"] as? Double
        views = obj["view_count"] as? Int
    }
}

/// Searches YouTube with yt-dlp ("ytsearch"), no browser or API key needed.
@MainActor
final class SongFinder: ObservableObject {
    static let shared = SongFinder()

    @Published var query = ""
    @Published private(set) var results: [FoundVideo] = []
    @Published private(set) var searching = false
    @Published private(set) var message: String?
    /// The download started from these results, shown under the search box.
    @Published private(set) var job: DownloadJob?
    private var process: Process?

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let ytdlp = Downloader.shared.ytdlp else { return }
        if let old = process, old.isRunning { old.terminate() }   // it may not have launched yet
        stopPreview()
        results = []
        message = nil
        searching = true

        let p = Process()
        p.executableURL = ytdlp
        p.environment = Downloader.toolEnvironment
        // "--" so the search can never be read as an option; the query rides inside the ytsearch "URL"
        p.arguments = ["--flat-playlist", "--dump-json", "--no-warnings", "--", "ytsearch8:\(q)"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        process = p
        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                Task { @MainActor in self.done(p, [], "Couldn't start yt-dlp: \(error.localizedDescription)") }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let found = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { FoundVideo(json: String($0)) }
            let failure = p.terminationStatus == 0 ? nil
                : (errText.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Search failed.")
            Task { @MainActor in self.done(p, found, failure) }
        }
    }

    private func done(_ p: Process, _ found: [FoundVideo], _ failure: String?) {
        guard p === process else { return }          // a newer search replaced this one
        process = nil
        searching = false
        results = found
        if let failure, p.terminationReason != .uncaughtSignal {
            message = failure.replacingOccurrences(of: "ERROR: ", with: "")
        } else if found.isEmpty {
            message = "No matches. Try other words."
        }
    }

    func download(_ v: FoundVideo) {
        stopPreview()
        job = Downloader.shared.start(v.link, openWhenDone: true)
    }

    // MARK: Preview (click a thumbnail: the first 30 seconds, audio only)

    static let previewLength: Double = 30
    /// Video id being previewed, and whether its stream is still being looked up.
    @Published private(set) var previewID: String?
    @Published private(set) var previewLoading = false
    @Published private(set) var previewProgress: Double = 0
    private var previewPlayer: AVPlayer?
    private var previewObserver: Any?
    private var previewLookup: Process?

    func togglePreview(_ v: FoundVideo) {
        if previewID == v.id { stopPreview(); return }
        stopPreview()
        guard let ytdlp = Downloader.shared.ytdlp else { return }
        previewID = v.id
        previewLoading = true
        message = nil
        if Player.shared.isPlaying, let u = Player.shared.url { Player.shared.toggle(u) }   // pause your song

        // Ask yt-dlp for a direct audio stream AVPlayer can play (m4a/AAC).
        let p = Process()
        p.executableURL = ytdlp
        p.environment = Downloader.toolEnvironment
        p.arguments = ["--no-warnings", "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[acodec^=mp4a]", "-g", "--", v.link]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        previewLookup = p
        let id = v.id
        DispatchQueue.global(qos: .userInitiated).async {
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let stream = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.flatMap { URL(string: String($0)) }
            Task { @MainActor in self.startPreview(id, stream: stream, lookup: p) }
        }
    }

    private func startPreview(_ id: String, stream: URL?, lookup: Process) {
        guard previewLookup === lookup, previewID == id else { return }   // stopped or replaced meanwhile
        previewLookup = nil
        previewLoading = false
        guard let stream else {
            previewID = nil
            message = "Couldn't load a preview for that one."
            return
        }
        let player = AVPlayer(url: stream)
        player.volume = Float(PlayerVolume.shared.volume)
        previewObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.previewProgress = min(t.seconds / Self.previewLength, 1)
                if t.seconds >= Self.previewLength { self.stopPreview() }
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.previewPlayer === player { self?.stopPreview() } }
        }
        previewPlayer = player
        player.play()
    }

    func stopPreview() {
        if let p = previewLookup, p.isRunning { p.terminate() }   // it may not have launched yet
        previewLookup = nil
        if let o = previewObserver { previewPlayer?.removeTimeObserver(o) }
        previewObserver = nil
        previewPlayer?.pause()
        previewPlayer = nil
        previewID = nil
        previewLoading = false
        previewProgress = 0
    }

    /// Keeps the preview in step with the app's volume slider.
    func setPreviewVolume(_ v: Double) { previewPlayer?.volume = Float(v) }
    var isPreviewPlaying: Bool { previewPlayer != nil }
}

/// Auto tab (SidebarTab.find): type a song and artist, pick one of the YouTube matches, and it downloads and opens in the editor.
struct FindView: View {
    @ObservedObject var finder = SongFinder.shared
    @ObservedObject var dl = Downloader.shared
    @ObservedObject var lib: Library
    @FocusState private var focused: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto Download").font(.title2.bold())
                    Text("Type a song and artist, pick the right video, and it's downloaded and opened in the editor.")
                        .foregroundStyle(.secondary)
                }

                if dl.toolsReady {
                    searchBox
                    if let job = finder.job, job.isActive || job.phase != .done { JobCard(job: job, lib: lib) }
                    results
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Finding songs uses yt-dlp and ffmpeg. Set them up in the Download tab first.", systemImage: "wrench.and.screwdriver")
                        Button("Go to Download") { lib.tab = .download }.buttonStyle(.purpleGlassProminent)
                    }
                    .padding(16)
                    .background(card)
                }

                Label("Only download videos you own or have permission to download.", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            dl.refreshTools()
            ThemeStore.shared.followNothing()
            focused = true
            // MP3TAGGER_SEARCH="…" searches at launch (used for screenshots)
            if finder.query.isEmpty, finder.results.isEmpty, let q = ProcessInfo.processInfo.environment["MP3TAGGER_SEARCH"] {
                finder.query = q
                finder.search()
            }
        }
        .onDisappear { finder.stopPreview() }
    }

    private var searchBox: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Song name and artist", text: $finder.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { finder.search() }
                if !finder.query.isEmpty {
                    Button { finder.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))

            Button { finder.search() } label: {
                if finder.searching { ProgressView().controlSize(.small).frame(width: 50) } else { Text("Search").frame(width: 50) }
            }
            .buttonStyle(.purpleGlassProminent)
            .disabled(finder.query.trimmingCharacters(in: .whitespaces).isEmpty || finder.searching)
        }
        .padding(16)
        .background(card)
    }

    @ViewBuilder private var results: some View {
        if let m = finder.message {
            Label(m, systemImage: "info.circle").foregroundStyle(.secondary)
        }
        if !finder.results.isEmpty {
            VStack(spacing: 0) {
                ForEach(finder.results) { v in
                    ResultRow(video: v, busy: finder.job?.isActive == true, finder: finder) { finder.download(v) }
                    if v != finder.results.last { Divider().padding(.leading, 148) }
                }
            }
            .padding(8)
            .background(card)
        }
    }

    private var card: some View {
        StyledPanel(cornerRadius: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [theme.purple.opacity(0.14), theme.indigo.opacity(0.16)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.rim.opacity(0.7), lineWidth: 1))
        }
    }
}

private struct ResultRow: View {
    let video: FoundVideo
    let busy: Bool
    @ObservedObject var finder: SongFinder
    let pick: () -> Void
    @StateObject private var hover = HoverState()
    @StateObject private var thumbHover = HoverState()

    var body: some View {
        let previewing = finder.previewID == video.id
        HStack(spacing: 12) {
            AsyncImage(url: video.thumbnail) { img in img.resizable().scaledToFill() } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 128, height: 72)
            .overlay {
                // Click the thumbnail to hear the start of the song
                if previewing || thumbHover.on {
                    ZStack {
                        Color.black.opacity(0.35)
                        ZStack {
                            Circle().fill(.black.opacity(0.45))
                            if previewing && !finder.previewLoading {
                                Circle().trim(from: 0, to: finder.previewProgress)
                                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.25), value: finder.previewProgress)
                            }
                            if previewing && finder.previewLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: previewing ? "stop.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let d = video.durationText, !previewing {
                    Text(d).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.7)))
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .onHover { thumbHover.on = $0 }
            .onTapGesture { finder.togglePreview(video) }
            .help(previewing ? "Stop preview" : "Play the first 30 seconds")

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title).font(.body.weight(.semibold)).lineLimit(2)
                Text([video.channel, video.viewsText].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Download", action: pick)
                .buttonStyle(.purpleGlass)
                .disabled(busy)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover.on ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture(count: 2) { if !busy { pick() } }
        .help("Double-click or press Download")
    }
}
