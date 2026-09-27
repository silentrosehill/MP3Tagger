import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MP3TaggerApp: App {
    var body: some Scene {
        WindowGroup("MP3 Tagger \(appVersion)") {
            ContentView()
                .frame(minWidth: 1045, minHeight: 555)   // window minimum 1045 × 607 (555 + the 52 pt toolbar)
        }
    }
}

/// "2.4" from the bundle's version (see CHANGELOG.md).
let appVersion: String = {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return v.hasSuffix(".0") ? String(v.dropLast(2)) : v
}()

enum SidebarTab: Hashable { case files, history, download, find, changelog }

final class TrackFile: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    @Published var tag: ID3Tag
    @Published var dirty = false
    /// Volume boost (1.5 dB steps) already applied to the audio on disk; `tag.gainSteps` is the wanted one.
    @Published var savedGain: Int

    init(url: URL) throws {
        self.url = url
        let t = try ID3.read(url: url)
        self.tag = t
        self.savedGain = t.gainSteps
    }
}

@MainActor
final class Library: ObservableObject {
    @Published var files: [TrackFile] = []
    @Published var selection: TrackFile.ID?
    @Published var status = ""
    @Published var dropTargeted = false
    @Published var coverTargeted = false
    /// `MP3TAGGER_TAB=history|download|changelog` opens on that tab (used for screenshots).
    @Published var tab: SidebarTab = {
        switch ProcessInfo.processInfo.environment["MP3TAGGER_TAB"] {
        case "history": .history
        case "download": .download
        case "find", "auto": .find
        case "changelog": .changelog
        default: .files
        }
    }()
    @Published var historySelection: HistoryEntry.ID?
    @Published var confirmClearHistory = false
    @Published var coverSearchOpen = false
    @Published var showThemePicker = false
    @Published var changelogSelection: String?
    let history = HistoryStore()

    var selected: TrackFile? { files.first { $0.id == selection } }

    // MARK: Downloaded songs — always listed in Files, across launches

    private static let downloadsKey = "downloadedFiles"
    @Published private(set) var downloadedPaths: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: Library.downloadsKey) ?? [])

    init() {
        // Bring back every song downloaded in the app that still exists.
        let existing = downloadedPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if existing.count != downloadedPaths.count { downloadedPaths = existing; persistDownloads() }
        let urls = existing.map { URL(fileURLWithPath: $0) }
            .sorted { (Self.modified($0) ?? .distantPast) > (Self.modified($1) ?? .distantPast) }
        add(urls, quiet: true)
    }

    private static func modified(_ u: URL) -> Date? {
        try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func isDownloaded(_ url: URL) -> Bool { downloadedPaths.contains(url.standardizedFileURL.path) }

    /// A download finished: list it in Files, and if it was picked in the Find tab, open it in the editor
    /// (unless you've moved on to another tab).
    func downloadFinished(_ url: URL, job: DownloadJob) {
        addDownloaded(url)
        status = "Downloaded \(url.lastPathComponent) — added to Files"
        if job.openWhenDone, tab == .find { openInEditor(url) }
    }

    /// Called when the downloader finishes a song.
    func addDownloaded(_ url: URL) {
        downloadedPaths.insert(url.standardizedFileURL.path)
        persistDownloads()
        add([url], quiet: true)
        if let f = files.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            // newest download at the top of the list
            files.removeAll { $0 === f }
            files.insert(f, at: 0)
        }
    }

    /// Takes a song off the Files list (the MP3 itself is not touched).
    func removeFromList(_ f: TrackFile) {
        files.removeAll { $0 === f }
        if downloadedPaths.remove(f.url.standardizedFileURL.path) != nil { persistDownloads() }
        if selection == f.id { selection = files.first?.id }
    }

    private func persistDownloads() {
        UserDefaults.standard.set(Array(downloadedPaths), forKey: Self.downloadsKey)
    }

    func add(_ urls: [URL], quiet: Bool = false) {
        var added = 0
        var known = Set(files.map(\.url.standardizedFileURL))
        for url in urls {
            let items: [URL]
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                items = (e?.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
            } else {
                items = [url]
            }
            for u in items where u.pathExtension.lowercased() == "mp3" && !known.contains(u.standardizedFileURL) {
                if let f = try? TrackFile(url: u) { files.append(f); known.insert(u.standardizedFileURL); added += 1 }
            }
        }
        if selection == nil { selection = files.first?.id }
        if !quiet { status = added > 0 ? "Added \(added) file(s)" : "No new MP3 files found" }
    }

    /// Asks where to save, defaulting to the song's current folder and name.
    func save(_ f: TrackFile) {
        let panel = NSSavePanel()
        panel.title = "Save Song"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.mp3]
        panel.canCreateDirectories = true
        panel.directoryURL = f.url.deletingLastPathComponent()
        panel.nameFieldStringValue = f.url.lastPathComponent
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if write(f, to: dest) {
            status = dest == f.url ? "Saved \(dest.lastPathComponent)" : "Saved to \(dest.path)"
        }
    }

    /// Asks for one folder and saves every changed song into it under its current file name.
    func saveAll() {
        let dirty = files.filter(\.dirty)
        if dirty.isEmpty { status = "Nothing to save"; return }
        if dirty.count == 1 { save(dirty[0]); return }

        let panel = NSOpenPanel()
        panel.title = "Save \(dirty.count) Songs"
        panel.message = "Choose a folder for the \(dirty.count) changed songs. Pick their current folder to update them in place."
        panel.prompt = "Save Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = dirty[0].url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let plan = dirty.map { ($0, folder.appendingPathComponent($0.url.lastPathComponent)) }
        let clashes = plan.filter { f, dest in
            dest.standardizedFileURL != f.url.standardizedFileURL && FileManager.default.fileExists(atPath: dest.path)
        }
        if !clashes.isEmpty {
            let alert = NSAlert()
            alert.messageText = clashes.count == 1 ? "\"\(clashes[0].1.lastPathComponent)\" already exists in that folder."
                                                   : "\(clashes.count) of these songs already exist in that folder."
            alert.informativeText = "Replacing them overwrites the existing files."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let saved = plan.filter { write($0.0, to: $0.1) }.count
        if saved == plan.count { status = "Saved \(saved) songs to \(folder.path)" }
    }

    /// Writes the tags, moves the editor over to the saved copy and records it in History.
    @discardableResult
    private func write(_ f: TrackFile, to dest: URL) -> Bool {
        do {
            let stored = try ID3.write(f.tag, from: f.url, to: dest, gainDelta: f.tag.gainSteps - f.savedGain)
            f.savedGain = stored
            f.tag.gainSteps = stored
            files.removeAll { $0 !== f && $0.url.standardizedFileURL == dest.standardizedFileURL }
            let oldPath = f.url.standardizedFileURL.path, newPath = dest.standardizedFileURL.path
            if oldPath != newPath, downloadedPaths.contains(oldPath) {
                // keep the original too if it still exists (Save… made a copy), and track the new one
                if !FileManager.default.fileExists(atPath: oldPath) { downloadedPaths.remove(oldPath) }
                downloadedPaths.insert(newPath)
                persistDownloads()
            }
            f.url = dest
            f.dirty = false
            history.record(url: dest, tag: f.tag)
            return true
        } catch {
            status = "Failed to save \(dest.lastPathComponent): \(error.localizedDescription)"
            if ID3.isPermissionError(error) { explainPermissionFailure(for: dest) }
            return false
        }
    }

    /// macOS blocked the write: say why and offer the fix.
    private func explainPermissionFailure(for url: URL) {
        let folder = url.deletingLastPathComponent().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "macOS blocked MP3 Tagger from saving in \"\(folder)\""
        alert.informativeText = """
        To allow it, open System Settings → Privacy & Security → Files & Folders and turn on \(folder) for MP3 Tagger \
        (or add MP3 Tagger under Full Disk Access). You can also save a copy to another folder, like Music.

        If the file itself is locked, select it in Finder, press ⌘I and untick "Locked".
        """
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Show File in Finder")
        alert.addButton(withTitle: "OK")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                NSWorkspace.shared.open(u)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            break
        }
    }

    /// Copies album-level info (album, album artist, year, genre, cover) from the selected file to all others.
    func applyAlbumInfoToAll(from src: TrackFile) {
        for f in files where f !== src {
            f.tag.album = src.tag.album
            f.tag.albumArtist = src.tag.albumArtist
            f.tag.year = src.tag.year
            f.tag.genre = src.tag.genre
            f.tag.cover = src.tag.cover
            f.tag.coverMime = src.tag.coverMime
            f.dirty = true
        }
        status = "Copied album info & cover to \(files.count - 1) file(s) — click Save All…"
    }

    /// Loads the file (if needed), selects it and switches to the Files tab.
    func openInEditor(_ url: URL) {
        if !files.contains(where: { $0.url == url }) { add([url]) }
        if let f = files.first(where: { $0.url == url }) { selection = f.id }
        tab = .files
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.mp3, .folder]
        if p.runModal() == .OK { add(p.urls) }
    }
}

struct ContentView: View {
    @StateObject private var lib = Library()
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(lib: lib, history: lib.history)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            DetailColumn(lib: lib)
                // status messages live under the editor only, so they never cover the sidebar
                .safeAreaInset(edge: .bottom) {
                    if !lib.status.isEmpty {
                        Text(lib.status).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal).padding(.vertical, 6)
                            .background(.bar)
                    }
                }
        }
        .toolbar {
            if #available(macOS 26.0, *) {
                // a title, not a button: no glass pill behind it
                ToolbarItem(placement: .navigation) { AppTitle() }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { AppTitle() }
            }
            ToolbarItemGroup {
                Button { lib.showThemePicker.toggle() } label: { Label("Theme", systemImage: "paintpalette.fill") }
                    .help("Change the app's color")
                    .popover(isPresented: $lib.showThemePicker, arrowEdge: .bottom) {
                        ThemePicker(store: themeStore)
                    }
                Button { lib.openPanel() } label: { Label("Add Files", systemImage: "plus") }
                Button { lib.saveAll() } label: { Label("Save All…", systemImage: "square.and.arrow.down.on.square") }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $lib.dropTargeted) { providers in
            loadURLs(providers) { lib.add($0) }
            return true
        }
        .overlay { FloatingPlayer() }
        .onAppear {
            themeStore.applyAppearance()
            // finished downloads land in the Files list, ready to tweak
            Downloader.shared.onFinished = { [lib] url, job in lib.downloadFinished(url, job: job) }
        }
        .environment(\.appTheme, themeStore.rendered)
        .environment(\.uiStyle, themeStore.style)
        .tint(themeStore.rendered.accent)
        .animation(.easeInOut(duration: 0.35), value: themeStore.rendered)
    }
}

/// App icon shown just before the window title ("MP3 Tagger 3.x").
struct AppTitle: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 22, height: 22)
            .padding(.trailing, -10)  // sit snug against the title
            .accessibilityHidden(true)
    }
}

struct DetailColumn: View {
    @ObservedObject var lib: Library
    @Environment(\.uiStyle) private var style

    var body: some View {
        Group {
            if lib.tab == .changelog {
                ChangelogView(lib: lib)
            } else if lib.tab == .download {
                DownloaderView(lib: lib)
            } else if lib.tab == .find {
                FindView(lib: lib)
            } else if lib.tab == .history {
                if let e = lib.history.entries.first(where: { $0.id == lib.historySelection }) {
                    HistoryDetail(entry: e, lib: lib).id(e.id)
                } else {
                    Text(lib.history.entries.isEmpty ? "Songs you save will show up here" : "Select a song")
                        .foregroundStyle(.secondary)
                        .onAppear { ThemeStore.shared.followNothing() }
                }
            } else if let f = lib.selected {
                EditorView(file: f, lib: lib).id(f.id)
            } else {
                Text("Select a file").foregroundStyle(.secondary)
                    .onAppear { ThemeStore.shared.followNothing() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if style == .mavericks {
                LinearGradient(colors: [Classic.windowTop, Classic.windowBottom], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
    }
}

/// Native AppKit vibrancy: lets the desktop show through, blurred, like Finder's sidebar.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

struct SidebarView: View {
    @ObservedObject var lib: Library
    @ObservedObject var history: HistoryStore
    @Environment(\.appTheme) private var theme
    @Environment(\.uiStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            GlassSegmented(selection: $lib.tab,
                           options: [(.files, "Files"), (.history, "History"), (.find, "Auto"), (.download, "Download"), (.changelog, "Changelog")],
                           icons: [.download: "arrow.down.circle", .changelog: "list.bullet.rectangle.portrait"])
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if lib.tab == .changelog {
                ChangelogSidebar(lib: lib)
            } else if lib.tab == .download || lib.tab == .find {
                DownloadsSidebar(lib: lib)
            } else if lib.tab == .files {
                List(lib.files, selection: $lib.selection) { f in
                    FileRow(file: f, downloaded: lib.isDownloaded(f.url), selected: lib.selection == f.id) { lib.status = $0 }
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                            Divider()
                            Button("Remove from List") { lib.removeFromList(f) }
                        }
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if lib.files.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "music.note.list").font(.largeTitle)
                            Text("Drop MP3 files or folders here")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                List(history.entries, selection: $lib.historySelection) { e in
                    HistoryRow(entry: e, selected: lib.historySelection == e.id) { lib.status = $0 }
                        .contextMenu {
                            Button("Open in Editor") { lib.openInEditor(e.url) }.disabled(!e.exists)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }.disabled(!e.exists)
                            Divider()
                            Button("Remove from History") { history.remove(e.id) }
                        }
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if history.entries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath").font(.largeTitle)
                            Text("No saved songs yet")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                if !history.entries.isEmpty {
                    Button("Clear History…") { lib.confirmClearHistory = true }
                        .buttonStyle(.purpleGlass)
                        .padding(.vertical, 8)
                        .confirmationDialog("Clear all history?", isPresented: $lib.confirmClearHistory) {
                            Button("Clear History", role: .destructive) { history.clear(); lib.historySelection = nil }
                        } message: {
                            Text("This only clears the list. Your MP3 files aren't touched.")
                        }
                }
            }
        }
        .background {
            if style == .mavericks {
                LinearGradient(colors: [Classic.sidebarTop, Classic.sidebarBottom], startPoint: .top, endPoint: .bottom)
                    .overlay(alignment: .trailing) { Rectangle().fill(Classic.sidebarEdge).frame(width: 1) }
                    .ignoresSafeArea()
            } else {
                ZStack {
                    VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
                    theme.sidebarTint
                }
                .ignoresSafeArea()
            }
        }
    }
}

struct FileRow: View {
    @ObservedObject var file: TrackFile
    var downloaded = false
    var selected = false
    @StateObject private var hover = HoverState()
    var onError: (String) -> Void = { _ in }
    var body: some View {
        HStack {
            PlayableThumb(url: file.url, data: file.tag.cover, onError: onError)
            VStack(alignment: .leading) {
                MarqueeText(text: file.tag.title.isEmpty ? file.url.deletingPathExtension().lastPathComponent : file.tag.title,
                            font: .body, active: hover.on || selected)
                Text(file.tag.artist.isEmpty ? "Unknown artist" : file.tag.artist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if downloaded {
                Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.secondary)
                    .help("Downloaded in MP3 Tagger")
            }
            if file.dirty { Circle().fill(.orange).frame(width: 7, height: 7) }
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }
}

struct CoverThumb: View {
    let data: Data?
    let size: CGFloat
    var body: some View {
        Group {
            if let data, let img = CoverImageCache.image(for: data, points: size) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 10))
    }
}

struct EditorView: View {
    @ObservedObject var file: TrackFile
    @ObservedObject var lib: Library
    @StateObject private var fx = CoverFX()

    private func binding(_ kp: WritableKeyPath<ID3Tag, String>) -> Binding<String> {
        Binding(get: { file.tag[keyPath: kp] },
                set: { new in
                    // text fields write back the same value on focus; only a real edit counts as a change
                    guard new != file.tag[keyPath: kp] else { return }
                    file.tag[keyPath: kp] = new
                    file.dirty = true
                })
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 10) {
                    GlassCover(data: file.tag.cover, fx: fx, targeted: lib.coverTargeted)
                        .onTapGesture { lib.coverSearchOpen = true }
                        .help("Click to search the web for cover art")
                        .sheet(isPresented: $lib.coverSearchOpen) {
                            CoverSearchView(query: coverQuery, onPick: { img in
                                lib.coverSearchOpen = false
                                // let the sheet slide away so the glass pour is visible
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { setCover(img) }
                            }, onClose: { lib.coverSearchOpen = false })
                        }
                        .onDrop(of: [.fileURL, .image], isTargeted: $lib.coverTargeted) { providers in
                            loadImage(providers) { setCover($0) }
                            return true
                        }
                    HStack {
                        Button { lib.coverSearchOpen = true } label: {
                            Label("Search Web", systemImage: "globe.americas.fill")
                        }
                        .help("Search the web for cover art")
                        Button(action: chooseCover) {
                            Label("Choose Image", systemImage: "photo.on.rectangle.angled")
                        }
                        .help("Choose an image from your Mac")
                        Button { fx.play(from: file.tag.cover); file.tag.cover = nil; file.dirty = true } label: {
                            Label("Remove Cover", systemImage: "trash")
                        }
                        .help("Remove the cover")
                        .disabled(file.tag.cover == nil)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.purpleGlassIcon)
                    Text("Click the cover to search, or drag an image onto it").font(.caption).foregroundStyle(.secondary)
                }

                Form {
                    TextField("Title", text: binding(\.title))
                    TextField("Artist", text: binding(\.artist))
                    TextField("Album", text: binding(\.album))
                    TextField("Album Artist", text: binding(\.albumArtist))
                    TextField("Year", text: binding(\.year))
                    TextField("Track #", text: binding(\.track))
                    TextField("Genre", text: binding(\.genre))

                    HStack {
                        Button("Save…") { lib.save(file) }
                            .keyboardShortcut("s")
                            .buttonStyle(.purpleGlassProminent)
                        Button("Apply Album & Cover to All") { lib.applyAlbumInfoToAll(from: file) }
                            .buttonStyle(.purpleGlass)
                            .disabled(lib.files.count < 2)
                    }
                    .padding(.top, 8)

                    Text(file.url.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).padding(.top, 4)

                    LoudnessCard(file: file)
                        .padding(.top, 12)
                }
                .frame(maxWidth: 420)
            }
            .padding(24)
        }
        // "Match album cover": the theme follows this song's cover, live as it changes
        .onAppear { ThemeStore.shared.follow(cover: file.tag.cover) }
        .onChange(of: file.tag.cover) { _, new in ThemeStore.shared.follow(cover: new) }
    }

    /// "Artist Album cover", falling back to the title or file name.
    private var coverQuery: String {
        let t = file.tag
        let name = !t.album.isEmpty ? t.album : (!t.title.isEmpty ? t.title : file.url.deletingPathExtension().lastPathComponent)
        let artist = t.albumArtist.isEmpty ? t.artist : t.albumArtist
        return [artist, name, "cover"].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func chooseCover() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let url = p.url, let img = NSImage(contentsOf: url) { setCover(img) }
    }

    private func setCover(_ img: NSImage) {
        guard let jpeg = jpegCover(from: img) else { lib.status = "Couldn't use that image"; return }
        fx.play(from: file.tag.cover)
        file.tag.cover = jpeg
        file.tag.coverMime = "image/jpeg"
        file.dirty = true
    }
}

/// Crops to a centered square, scales to at most 1000×1000 and encodes as JPEG —
/// the format/size combo Spotify displays reliably for local files.
func jpegCover(from img: NSImage, maxSide: Int = 1000) -> Data? {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let side = min(cg.width, cg.height)
    let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
    guard let square = cg.cropping(to: crop) else { return nil }
    let out = min(side, maxSide)
    guard let ctx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(square, in: CGRect(x: 0, y: 0, width: out, height: out))
    guard let scaled = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
}

// MARK: - Drag & drop helpers

func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
}

func loadImage(_ providers: [NSItemProvider], completion: @escaping @MainActor (NSImage) -> Void) {
    guard let p = providers.first else { return }
    if p.canLoadObject(ofClass: URL.self) {
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let img = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(img) } }
        }
    } else if p.canLoadObject(ofClass: NSImage.self) {
        _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
            guard let img = obj as? NSImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(img) } }
        }
    }
}
