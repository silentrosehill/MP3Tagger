import SwiftUI
import WebKit

enum SearchMode: Hashable { case albums, web }

enum SearchEngine: String, CaseIterable, Identifiable {
    case google = "Google", duckDuckGo = "DuckDuckGo", bing = "Bing"
    var id: String { rawValue }
    func url(for q: String) -> URL {
        var c: URLComponents
        switch self {
        case .google:
            c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "udm", value: "2")]  // udm=2: Images
        case .duckDuckGo:
            c = URLComponents(string: "https://duckduckgo.com/")!
            c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "iax", value: "images"), URLQueryItem(name: "ia", value: "images")]
        case .bing:
            c = URLComponents(string: "https://www.bing.com/images/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
        }
        return c.url!
    }
}

/// One album from Apple's catalog (iTunes Search API — free, no account needed).
struct AlbumResult: Identifiable, Decodable {
    let collectionId: Int
    let collectionName: String
    let artistName: String
    let artworkUrl100: String
    var id: Int { collectionId }
    func artwork(_ px: Int) -> URL? { URL(string: artworkUrl100.replacingOccurrences(of: "100x100bb", with: "\(px)x\(px)bb")) }
}

/// Cover search: official album art from Apple's catalog, or the web (WebKit, Safari's engine)
/// where you right-click an image → "Use as Cover Art".
@MainActor
final class CoverSearchModel: ObservableObject {
    @Published var query: String
    @Published var mode: SearchMode = .albums
    @Published var engine: SearchEngine = .google
    @Published var albums: [AlbumResult] = []
    @Published var albumsLoading = false
    @Published var albumsError: String?
    private var webLoaded = false
    @Published var message: String?
    /// A low-resolution pick waiting for "Use Anyway".
    @Published var smallPick: NSImage?
    weak var webView: CoverWebView?
    var onPick: (NSImage) -> Void = { _ in }

    static let minSide: CGFloat = 300
    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"

    init(query: String) { self.query = query }

    func search() {
        switch mode {
        case .albums: searchAlbums()
        case .web: searchWeb()
        }
    }

    /// Called when switching modes: run the current query in the newly shown mode.
    func modeChanged() {
        if mode == .web, !webLoaded { searchWeb() }
    }

    func searchWeb() {
        guard let webView else { return }
        webLoaded = true
        webView.load(URLRequest(url: engine.url(for: query)))
    }

    func searchAlbums() {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        let term = query.replacingOccurrences(of: #"\bcover\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        c.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: "album"),
                        URLQueryItem(name: "limit", value: "40")]
        albumsLoading = true
        albumsError = nil
        webLoaded = false  // web results are now stale for the new query
        Task {
            struct Response: Decodable { let results: [AlbumResult] }
            do {
                let (data, _) = try await URLSession.shared.data(from: c.url!)
                albums = try JSONDecoder().decode(Response.self, from: data).results
                if albums.isEmpty { albumsError = "No albums found. Try fewer words, or search the Web tab." }
            } catch {
                albums = []
                albumsError = "Couldn't reach Apple's catalog. Check your connection."
            }
            albumsLoading = false
        }
    }

    func pick(_ album: AlbumResult) {
        message = "Getting \(album.collectionName) artwork…"
        Task {
            guard let url = album.artwork(1200), let img = await Self.fetch(url.absoluteString) else {
                message = "Couldn't download that artwork."
                return
            }
            message = nil
            onPick(img)
        }
    }

    func use(src: String?) {
        guard let src, !src.isEmpty else {
            message = "No image found there. Right-click directly on a picture."
            return
        }
        smallPick = nil
        message = "Getting image…"
        Task {
            guard let img = await Self.fetch(src) else {
                message = "Couldn't download that image. Try clicking it first and using the larger preview."
                return
            }
            let px = Self.pixelSize(img)
            if min(px.width, px.height) < Self.minSide {
                smallPick = img
                message = "That's a small thumbnail (\(Int(px.width))×\(Int(px.height))). Click it to open the larger preview, then right-click the big image."
                return
            }
            message = nil
            onPick(img)
        }
    }

    private static func fetch(_ src: String) async -> NSImage? {
        if src.hasPrefix("data:") {
            guard let comma = src.firstIndex(of: ",") else { return nil }
            let header = src[..<comma], payload = String(src[src.index(after: comma)...])
            let data = header.contains(";base64") ? Data(base64Encoded: payload)
                                                  : payload.removingPercentEncoding.map { Data($0.utf8) }
            return data.flatMap(NSImage.init(data:))
        }
        guard let url = URL(string: src) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.google.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return NSImage(data: data)
    }

    private static func pixelSize(_ img: NSImage) -> CGSize {
        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { return CGSize(width: cg.width, height: cg.height) }
        return img.size
    }
}

/// WKWebView that adds "Use as Cover Art" to the right-click menu.
final class CoverWebView: WKWebView {
    var onUseImage: (String?) -> Void = { _ in }
    private var menuPoint = CGPoint.zero

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let p = convert(event.locationInWindow, from: nil)
        menuPoint = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        let item = NSMenuItem(title: "Use as Cover Art", action: #selector(useImage), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "photo.badge.checkmark", accessibilityDescription: nil)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    /// Finds the largest image (or CSS background image) under the click point.
    @objc private func useImage() {
        let js = """
        (function(x, y) {
          const els = document.elementsFromPoint(x, y);
          let best = null, area = 0;
          for (const el of els) {
            if (el.tagName === 'IMG') {
              const a = (el.naturalWidth || el.width) * (el.naturalHeight || el.height);
              if (a > area) { area = a; best = el; }
            }
          }
          if (best) return best.currentSrc || best.src;
          for (const el of els) {
            const m = getComputedStyle(el).backgroundImage.match(/url\\(["']?(.*?)["']?\\)/);
            if (m) return m[1];
          }
          return null;
        })(\(menuPoint.x), \(menuPoint.y))
        """
        evaluateJavaScript(js) { [weak self] result, _ in
            self?.onUseImage(result as? String)
        }
    }
}

struct CoverWebViewRep: NSViewRepresentable {
    let model: CoverSearchModel

    func makeNSView(context: Context) -> CoverWebView {
        let v = CoverWebView(frame: .zero, configuration: makeBrowserConfiguration())  // Safari UA, saved sign-ins
        AdBlock.apply(to: v)
        v.onUseImage = { [weak model] src in model?.use(src: src) }
        model.webView = v
        if model.mode == .web { model.searchWeb() }
        return v
    }

    func updateNSView(_ v: CoverWebView, context: Context) {}
}

struct CoverSearchView: View {
    @StateObject private var model: CoverSearchModel
    let onClose: () -> Void

    init(query: String, onPick: @escaping (NSImage) -> Void, onClose: @escaping () -> Void) {
        let m = CoverSearchModel(query: query)
        m.onPick = onPick
        _model = StateObject(wrappedValue: m)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GlassSegmented(selection: $model.mode, options: [(.albums, "Albums"), (.web, "Web")])
                    .fixedSize()
                .onChange(of: model.mode) { model.modeChanged() }

                if model.mode == .web {
                    Button { model.webView?.goBack() } label: { Image(systemName: "chevron.left") }.help("Back")
                    Button { model.webView?.goForward() } label: { Image(systemName: "chevron.right") }.help("Forward")
                }
                TextField(model.mode == .albums ? "Artist and album" : "Search the web", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                if model.mode == .web {
                    Picker("Engine", selection: $model.engine) {
                        ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: model.engine) { model.searchWeb() }
                }
                Button("Search") { model.search() }.buttonStyle(.purpleGlassProminent)
                Button("Done", action: onClose).keyboardShortcut(.cancelAction).buttonStyle(.purpleGlass)
            }
            .buttonStyle(.purpleGlass)
            .padding(10)
            .background(.bar)

            Divider()
            ZStack {
                // Keep the browser alive while on the Albums tab so its page/history survive switching.
                CoverWebViewRep(model: model).opacity(model.mode == .web ? 1 : 0)
                if model.mode == .albums {
                    AlbumGrid(model: model).background(Color(nsColor: .windowBackgroundColor))
                }
            }

            Divider()
            HStack(spacing: 10) {
                Image(systemName: model.message == nil ? "cursorarrow.click.2" : "info.circle")
                    .foregroundStyle(.secondary)
                Text(model.message ?? (model.mode == .albums
                     ? "Official artwork from Apple's catalog. Click an album to use its cover."
                     : "Right-click any image → Use as Cover Art. If Google asks you to verify, tick the box or switch engines."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if let small = model.smallPick {
                    Button("Use Anyway") { model.smallPick = nil; model.onPick(small) }.buttonStyle(.purpleGlass)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 620, idealHeight: 720)
        .environment(\.appTheme, ThemeStore.shared.rendered)
        .environment(\.uiStyle, ThemeStore.shared.style)
        .tint(ThemeStore.shared.rendered.accent)
        .onAppear { model.search() }
    }
}

struct AlbumGrid: View {
    @ObservedObject var model: CoverSearchModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)], spacing: 20) {
                ForEach(model.albums) { album in
                    AlbumCell(album: album) { model.pick(album) }
                }
            }
            .padding(20)
        }
        .overlay {
            if model.albumsLoading {
                ProgressView()
            } else if let err = model.albumsError {
                Text(err).foregroundStyle(.secondary)
            }
        }
    }
}

struct AlbumCell: View {
    let album: AlbumResult
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: album.artwork(400)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                    LinearGradient(colors: [.white.opacity(hover.on ? 0.9 : 0.35), .white.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: hover.on ? 2 : 1))
                .shadow(color: .black.opacity(hover.on ? 0.35 : 0.15), radius: hover.on ? 14 : 6, y: hover.on ? 8 : 3)
                .scaleEffect(hover.on ? 1.04 : 1)

                Text(album.collectionName).font(.callout.weight(.medium)).lineLimit(1)
                Text(album.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover.on)
        .help("\(album.collectionName) — \(album.artistName)")
    }
}
