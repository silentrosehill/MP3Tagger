import SwiftUI
import AppKit

/// One download, from link to tagged MP3.
@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case starting, downloading, converting, tagging, done, cancelled
        case failed(String)
    }

    let id = UUID()
    let link: String
    @Published var title: String
    @Published var thumbnail: URL?
    @Published var progress: Double = 0
    @Published var phase: Phase = .starting
    @Published var file: URL?
    fileprivate var process: Process?
    fileprivate var lastError: String?
    fileprivate var cancelRequested = false

    init(link: String) {
        self.link = link
        self.title = link
    }

    var isActive: Bool {
        switch phase {
        case .starting, .downloading, .converting, .tagging: return true
        default: return false
        }
    }

    var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case .downloading: return "Downloading \(Int(progress * 100))%"
        case .converting: return "Converting to MP3…"
        case .tagging: return "Adding cover & tags…"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .failed(let msg): return msg
        }
    }
}

/// Audio downloader built on yt-dlp (fetching) and ffmpeg (MP3 conversion), installed via Homebrew.
@MainActor
final class Downloader: ObservableObject {
    static let shared = Downloader()

    enum Quality: String, CaseIterable, Identifiable {
        case best = "Best (VBR)", k320 = "320 kbps", k192 = "192 kbps", k128 = "128 kbps"
        var id: String { rawValue }
        var ytdlpValue: String {
            switch self { case .best: return "0"; case .k320: return "320K"; case .k192: return "192K"; case .k128: return "128K" }
        }
    }

    @Published var link = ""
    @Published var quality: Quality = Quality(rawValue: UserDefaults.standard.string(forKey: "dlQuality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "dlQuality") }
    }
    @Published var folder: URL = {
        if let p = UserDefaults.standard.string(forKey: "dlFolder") { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
    }() {
        didSet { UserDefaults.standard.set(folder.path, forKey: "dlFolder") }
    }
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var ytdlp: URL?
    @Published private(set) var ffmpeg: URL?
    @Published private(set) var brew: URL?
    @Published private(set) var toolTaskRunning = false
    @Published private(set) var toolLog = ""
    @Published var message: String?
    @Published var browserOpen = false
    /// Bring new downloads to Spotify's loudness (lossless).
    @Published var matchLoudness: Bool = UserDefaults.standard.object(forKey: "dlMatchLoudness") as? Bool ?? true {
        didSet { UserDefaults.standard.set(matchLoudness, forKey: "dlMatchLoudness") }
    }

    /// Called with each finished MP3 (the app adds it to the Files list).
    var onFinished: (URL) -> Void = { _ in }

    var toolsReady: Bool { ytdlp != nil && ffmpeg != nil }
    var latest: DownloadJob? { jobs.first }

    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin"]
    private static var toolEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        return env
    }

    private init() {
        refreshTools()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for job in Downloader.shared.jobs where job.isActive { job.process?.terminate() }
            }
        }
    }

    func refreshTools() {
        func find(_ name: String) -> URL? {
            Self.searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        ytdlp = find("yt-dlp")
        ffmpeg = find("ffmpeg")
        brew = find("brew")
    }

    // MARK: Setup & upkeep (Homebrew)

    func installTools() { runBrew(["install", "yt-dlp", "ffmpeg"], done: "Tools installed. You're ready to download.") }
    func updateYtDlp() { runBrew(["upgrade", "yt-dlp"], done: "yt-dlp is up to date.") }

    private func runBrew(_ args: [String], done: String) {
        guard let brew, !toolTaskRunning else { return }
        toolTaskRunning = true
        toolLog = "$ brew \(args.joined(separator: " "))\n"
        message = nil
        let p = Process()
        p.executableURL = brew
        p.arguments = args
        p.environment = Self.toolEnvironment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.toolLog = String((self.toolLog + chunk).suffix(6000))
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.toolTaskRunning = false
                self.refreshTools()
                self.message = proc.terminationStatus == 0 ? done : "Homebrew reported a problem (see the log above)."
            }
        }
        do { try p.run() } catch {
            toolTaskRunning = false
            message = "Couldn't run Homebrew: \(error.localizedDescription)"
        }
    }

    // MARK: Downloading

    func paste() {
        if let s = NSPasteboard.general.string(forType: .string) { link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.directoryURL = folder
        p.prompt = "Save Here"
        if p.runModal() == .OK, let u = p.url { folder = u }
    }

    func start() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: text), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else {
            message = "That doesn't look like a link. Paste a full https:// address."
            return
        }
        guard let ytdlp, let ffmpeg else { return }
        message = nil
        link = ""
        let job = DownloadJob(link: text)
        jobs.insert(job, at: 0)

        let p = Process()
        p.executableURL = ytdlp
        p.environment = Self.toolEnvironment
        p.arguments = [
            "--no-playlist", "--no-mtime",
            "-x", "--audio-format", "mp3", "--audio-quality", quality.ytdlpValue,
            "--embed-thumbnail", "--embed-metadata",
            "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "-P", folder.path, "-o", "%(title).150B.%(ext)s",
            "--newline", "--progress", "--no-simulate",
            "--progress-template", "download:[dl] %(progress._percent_str)s",
            "--print", "before_dl:[title]%(title)s",
            "--print", "before_dl:[thumb]%(thumbnail)s",
            "--print", "after_move:[file]%(filepath)s",
            "--", text,  // "--" so a link can never be read as an option
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let reader = LineReader()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let lines = reader.feed(h.availableData)
            guard !lines.isEmpty else { return }
            Task { @MainActor in lines.forEach { Self.handle(line: $0, job: job) } }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor in self.finish(job, status: status) }
        }
        job.process = p
        do { try p.run() } catch {
            job.phase = .failed("Couldn't start yt-dlp: \(error.localizedDescription)")
        }
    }

    private static func handle(line raw: String, job: DownloadJob) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[title]") {
            job.title = String(line.dropFirst(7))
        } else if line.hasPrefix("[thumb]") {
            job.thumbnail = URL(string: String(line.dropFirst(7)))
        } else if line.hasPrefix("[file]") {
            job.file = URL(fileURLWithPath: String(line.dropFirst(6)))
        } else if line.hasPrefix("[dl]") {
            let pct = line.dropFirst(4).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
            if let v = Double(pct) {
                job.progress = min(max(v / 100, 0), 1)
                job.phase = v >= 100 ? .converting : .downloading
            }
        } else if line.hasPrefix("ERROR:") {
            job.lastError = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
    }

    func cancel(_ job: DownloadJob) {
        guard job.isActive else { return }
        job.cancelRequested = true
        job.process?.terminate()
    }

    func remove(_ job: DownloadJob) {
        cancel(job)
        jobs.removeAll { $0 === job }
    }

    private func finish(_ job: DownloadJob, status: Int32) {
        job.process = nil
        if job.cancelRequested { job.phase = .cancelled; return }
        guard status == 0, let file = job.file else {
            job.phase = .failed(Self.friendly(job.lastError) ?? "Download failed (yt-dlp exit code \(status)).")
            return
        }
        job.phase = .tagging
        let loud = matchLoudness
        Task.detached(priority: .userInitiated) {
            let result = Result { try Self.polishTags(file, matchLoudness: loud) }
            await MainActor.run {
                switch result {
                case .success(let title):
                    job.title = title
                    job.phase = .done
                    self.onFinished(file)
                case .failure:
                    // The MP3 itself is fine; only the tag clean-up failed.
                    job.phase = .done
                    self.onFinished(file)
                }
            }
        }
    }

    private static func friendly(_ error: String?) -> String? {
        guard let e = error else { return nil }
        let l = e.lowercased()
        if l.contains("sign in to confirm") || l.contains("not a bot") {
            return "YouTube asked to confirm you're not a bot. Try again later, or click Update yt-dlp."
        }
        if l.contains("private video") || l.contains("unavailable") { return "This video is private or unavailable." }
        if l.contains("unsupported url") { return "That site or link isn't supported." }
        if l.contains("http error 403") || l.contains("nsig") || l.contains("signature") {
            return "YouTube changed something. Click Update yt-dlp, then try again."
        }
        return e
    }

    /// Square cover, "Artist - Title (Official Video)" → artist + clean title, optional Spotify-level loudness,
    /// and ID3 v2.3 for Spotify.
    nonisolated static func polishTags(_ file: URL, matchLoudness: Bool = false) throws -> String {
        var tag = try ID3.read(url: file)
        var title = tag.title.isEmpty ? file.deletingPathExtension().lastPathComponent : tag.title
        let noise = #"\s*[\(\[][^\)\]]*\b(official|lyrics?|audio|video|visuali[sz]er|hd|hq|4k|mv|m/v)\b[^\)\]]*[\)\]]"#
        while let r = title.range(of: noise, options: [.regularExpression, .caseInsensitive]) { title.removeSubrange(r) }
        if let dash = title.range(of: " - ") {
            let left = title[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = title[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty {
                tag.artist = left
                title = right
            }
        }
        tag.title = title.trimmingCharacters(in: .whitespaces)
        if let cover = tag.cover, let img = NSImage(data: cover), let jpeg = jpegCover(from: img) {
            tag.cover = jpeg
            tag.coverMime = "image/jpeg"
        }
        var delta = 0
        if matchLoudness, let r = try? Loudness.measure(file) {
            delta = Loudness.recommendedSteps(for: r).steps
            tag.gainSteps += delta
        }
        try ID3.write(tag, from: file, to: file, gainDelta: delta)
        return tag.title
    }
}

/// Splits streamed process output into lines (output arrives in order on one background queue).
final class LineReader: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let r = buffer.rangeOfCharacter(from: .newlines) {
            lines.append(String(buffer[..<r.lowerBound]))
            buffer.removeSubrange(..<r.upperBound)
        }
        return lines
    }
}

// MARK: - Views

struct DownloadRow: View {
    @ObservedObject var job: DownloadJob
    @StateObject private var hover = HoverState()
    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: job.thumbnail) { img in img.resizable().scaledToFill() } placeholder: {
                ZStack { Rectangle().fill(.quaternary); Image(systemName: "arrow.down.circle").foregroundStyle(.secondary) }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(text: job.title, font: .body, active: hover.on)
                if job.isActive {
                    ProgressView(value: job.phase == .downloading ? job.progress : nil)
                        .progressViewStyle(.linear).controlSize(.small)
                }
                Text(job.statusText).font(.caption).foregroundStyle(isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }
    private var isFailed: Bool { if case .failed = job.phase { return true }; return false }
}

struct DownloadsSidebar: View {
    @ObservedObject var dl = Downloader.shared
    @ObservedObject var lib: Library

    var body: some View {
        List(dl.jobs) { job in
            DownloadRow(job: job)
                .contextMenu {
                    if job.isActive { Button("Cancel") { dl.cancel(job) } }
                    if let f = job.file, job.phase == .done {
                        Button("Open in Editor") { lib.openInEditor(f) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    }
                    Divider()
                    Button("Remove from List") { dl.remove(job) }
                }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if dl.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle)
                    Text("No downloads yet")
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct DownloaderView: View {
    @ObservedObject var dl = Downloader.shared
    @ObservedObject var lib: Library
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download Audio").font(.title2.bold())
                    Text("Paste a video link to save its audio as a tagged MP3, ready for Spotify.")
                        .foregroundStyle(.secondary)
                }

                if dl.toolsReady {
                    form
                    if let job = dl.latest { JobCard(job: job, lib: lib) }
                } else {
                    setupCard
                }

                if dl.toolTaskRunning || !dl.toolLog.isEmpty && !dl.toolsReady {
                    ScrollView {
                        Text(dl.toolLog).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(height: 120)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.2)))
                }
                if let m = dl.message {
                    Label(m, systemImage: "info.circle").foregroundStyle(.secondary)
                }

                Label("Only download videos you own or have permission to download.", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear {
            dl.refreshTools()
            ThemeStore.shared.follow(cover: nil)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if dl.link.isEmpty {
                    // Empty link box: clicking it opens YouTube in the app.
                    Button { dl.browserOpen = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.rectangle.fill").foregroundStyle(theme.pink)
                            Text("Browse YouTube, or paste a link…").foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.6)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open YouTube to pick a video")
                } else {
                    TextField("https://www.youtube.com/watch?v=…", text: $dl.link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { dl.start() }
                    Button { dl.link = "" } label: { Label("Clear", systemImage: "xmark.circle.fill") }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Clear")
                }
                Button { dl.browserOpen = true } label: { Label("YouTube", systemImage: "play.rectangle") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.purpleGlassIcon(32))
                    .help("Browse YouTube")
                Button { dl.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.purpleGlassIcon(32))
                    .help("Paste link")
                Button("Download") { dl.start() }
                    .buttonStyle(.purpleGlassProminent)
                    .disabled(dl.link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 12) {
                Picker("Quality", selection: $dl.quality) {
                    ForEach(Downloader.Quality.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Toggle("Match Spotify loudness", isOn: $dl.matchLoudness)
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Boost quiet downloads to Spotify's level (lossless)")
                Button { dl.chooseFolder() } label: {
                    Label(dl.folder.lastPathComponent, systemImage: "folder")
                }
                .buttonStyle(.purpleGlass)
                .help("Save to: \(dl.folder.path)")
                Spacer()
                Button { dl.updateYtDlp() } label: {
                    if dl.toolTaskRunning { ProgressView().controlSize(.small) } else { Label("Update yt-dlp", systemImage: "arrow.triangle.2.circlepath") }
                }
                .buttonStyle(.purpleGlass)
                .disabled(dl.toolTaskRunning || dl.brew == nil)
                .help("Get the latest yt-dlp (fixes most download errors after YouTube changes)")
            }
        }
        .padding(16)
        .background(glassCard)
        .sheet(isPresented: $dl.browserOpen) {
            YouTubeBrowserView(onDownload: { link in
                dl.browserOpen = false
                dl.link = link
                dl.start()
            }, onClose: { dl.browserOpen = false })
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("One-time setup", systemImage: "wrench.and.screwdriver").font(.headline)
            Text("Downloading uses two free, open-source tools: yt-dlp (fetches the audio) and ffmpeg (converts it to MP3).")
                .foregroundStyle(.secondary)
            toolLine("yt-dlp", dl.ytdlp)
            toolLine("ffmpeg", dl.ffmpeg)
            HStack {
                if dl.brew != nil {
                    Button { dl.installTools() } label: {
                        if dl.toolTaskRunning {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing… (this can take a few minutes)") }
                        } else {
                            Label("Install with Homebrew", systemImage: "arrow.down.app")
                        }
                    }
                    .buttonStyle(.purpleGlassProminent)
                    .disabled(dl.toolTaskRunning)
                } else {
                    Text("Install Homebrew from brew.sh first, then run: brew install yt-dlp ffmpeg")
                        .font(.callout).textSelection(.enabled)
                }
                Button("Check Again") { dl.refreshTools() }.buttonStyle(.purpleGlass)
            }
        }
        .padding(16)
        .background(glassCard)
    }

    private func toolLine(_ name: String, _ path: URL?) -> some View {
        Label {
            Text(path == nil ? "\(name) — not installed" : "\(name) — \(path!.path)")
        } icon: {
            Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(path == nil ? .orange : .green)
        }
        .font(.callout)
    }

    private var glassCard: some View {
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

/// Big card for the most recent download.
struct JobCard: View {
    @ObservedObject var job: DownloadJob
    @ObservedObject var lib: Library

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: job.thumbnail) { img in img.resizable().scaledToFill() } placeholder: {
                ZStack { Rectangle().fill(.quaternary); ProgressView().controlSize(.small) }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rim, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text(job.title).font(.headline).lineLimit(2)
                if job.isActive {
                    ProgressView(value: job.phase == .downloading ? job.progress : nil).progressViewStyle(.linear)
                }
                Text(job.statusText).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                HStack {
                    if job.isActive {
                        Button("Cancel") { Downloader.shared.cancel(job) }.buttonStyle(.purpleGlass)
                    }
                    if job.phase == .done, let f = job.file {
                        Button("Open in Editor") { lib.openInEditor(f) }.buttonStyle(.purpleGlassProminent)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }.buttonStyle(.purpleGlass)
                    }
                }
            }
        }
    }
}
