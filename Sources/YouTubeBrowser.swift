import SwiftUI
import WebKit
import Combine

/// Built-in ad blocker for the app's browsers (Safari's own extensions can't run outside Safari).
/// A WebKit content rule list blocks ad/tracker requests and hides ad slots; a small script skips video ads.
@MainActor
enum AdBlock {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "adBlock") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "adBlock") }
    }

    private static var compiled: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    private static var compiling = false

    private static let blockedHosts = [
        "doubleclick\\.net", "googlesyndication\\.com", "googleadservices\\.com", "google-analytics\\.com",
        "googletagservices\\.com", "googletagmanager\\.com", "adservice\\.google\\.", "pagead2\\.googlesyndication\\.com",
        "ads\\.youtube\\.com", "scorecardresearch\\.com", "amazon-adsystem\\.com", "adnxs\\.com", "taboola\\.com",
        "outbrain\\.com", "criteo\\.com", "moatads\\.com",
    ]
    private static let blockedYouTubePaths = [
        "youtube\\.com/api/stats/ads", "youtube\\.com/pagead/", "youtube\\.com/ptracking", "youtube\\.com/get_midroll_",
        "youtube\\.com/api/stats/qoe\\?.*adformat",
    ]
    private static let hiddenSelectors = [
        "ytd-ad-slot-renderer", "ytd-in-feed-ad-layout-renderer", "ytd-display-ad-renderer", "ytd-promoted-sparkles-web-renderer",
        "ytd-promoted-video-renderer", "ytd-banner-promo-renderer", "ytd-statement-banner-renderer", "ytd-companion-slot-renderer",
        "ytd-player-legacy-desktop-watch-ads-renderer", "#masthead-ad", "#player-ads", ".ytp-ad-overlay-container",
        "ytd-rich-item-renderer:has(ytd-ad-slot-renderer)", "ytd-merch-shelf-renderer", "ytd-engagement-panel-section-list-renderer[target-id=engagement-panel-ads]",
    ]

    private static var rulesJSON: String {
        var rules: [[String: Any]] = []
        for h in blockedHosts { rules.append(["trigger": ["url-filter": "^https?://[^/]*" + h], "action": ["type": "block"]]) }
        for p in blockedYouTubePaths { rules.append(["trigger": ["url-filter": p], "action": ["type": "block"]]) }
        rules.append(["trigger": ["url-filter": ".*", "if-domain": ["*youtube.com"]],
                      "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")]])
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }

    /// Clicks "Skip", and fast-forwards unskippable video ads.
    static let skipScript = WKUserScript(source: """
        (function () {
          const tick = () => {
            const player = document.querySelector('.html5-video-player');
            if (!player || !player.classList.contains('ad-showing')) return;
            const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
            if (skip) { skip.click(); return; }
            const v = document.querySelector('video');
            if (v && isFinite(v.duration) && v.duration > 0) { v.muted = true; v.currentTime = v.duration; }
          };
          setInterval(tick, 400);
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

    static func ruleList(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { return done(compiled) }
        waiting.append(done)
        guard !compiling else { return }
        compiling = true
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mp3tagger-adblock-v1",
                                                                encodedContentRuleList: rulesJSON) { list, _ in
            Task { @MainActor in
                compiled = list
                compiling = false
                let w = waiting; waiting = []
                w.forEach { $0(list) }
            }
        }
    }

    /// Turns blocking on/off for a web view (reloads so the change takes effect).
    static func apply(to webView: WKWebView, reload: Bool = false) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        ucc.removeAllUserScripts()
        guard enabled else { if reload { webView.reload() }; return }
        ucc.addUserScript(skipScript)
        ruleList { list in
            if let list { ucc.add(list) }
            if reload { webView.reload() }
        }
    }
}

/// Shared config for the app's browsers: Safari user agent (full desktop sites) and the app's
/// persistent website data store, so signing in to YouTube once keeps you signed in.
func makeBrowserConfiguration() -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.applicationNameForUserAgent = "Version/19.0 Safari/605.1.15"
    config.websiteDataStore = .default()
    config.mediaTypesRequiringUserActionForPlayback = []
    return config
}

enum YouTubeLink {
    /// True for a single video page (watch, shorts, youtu.be, YouTube Music).
    static func isVideo(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        if host == "youtu.be" { return url.pathComponents.count > 1 }
        guard host.hasSuffix("youtube.com") else { return false }
        if url.path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "v" } ?? false
        }
        return url.path.hasPrefix("/shorts/")
    }

    /// Strips playlist/timestamp extras so only the one video is downloaded.
    static func clean(_ url: URL) -> String {
        guard url.path == "/watch", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.queryItems = c.queryItems?.filter { $0.name == "v" }
        return c.url?.absoluteString ?? url.absoluteString
    }
}

@MainActor
final class YouTubeBrowserModel: ObservableObject {
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false
    @Published var adBlock = AdBlock.enabled
    weak var webView: YouTubeWebView?
    private var bag: Set<AnyCancellable> = []

    var onDownload: (String) -> Void = { _ in }

    var isVideo: Bool { YouTubeLink.isVideo(url) }

    func attach(_ v: YouTubeWebView) {
        webView = v
        v.publisher(for: \.url).receive(on: RunLoop.main).sink { [weak self] in self?.url = $0 }.store(in: &bag)
        v.publisher(for: \.canGoBack).receive(on: RunLoop.main).sink { [weak self] in self?.canGoBack = $0 }.store(in: &bag)
        v.publisher(for: \.canGoForward).receive(on: RunLoop.main).sink { [weak self] in self?.canGoForward = $0 }.store(in: &bag)
        v.publisher(for: \.isLoading).receive(on: RunLoop.main).sink { [weak self] in self?.loading = $0 }.store(in: &bag)
    }

    func home() { webView?.load(URLRequest(url: URL(string: "https://www.youtube.com/")!)) }

    func downloadCurrent() {
        guard let url, YouTubeLink.isVideo(url) else { return }
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())")
        onDownload(YouTubeLink.clean(url))
    }

    func toggleAdBlock() {
        adBlock.toggle()
        AdBlock.enabled = adBlock
        if let webView { AdBlock.apply(to: webView, reload: true) }
    }
}

/// WKWebView that adds "Download Audio" when right-clicking a video link, and keeps sign-in pop-ups in-app.
final class YouTubeWebView: WKWebView, WKUIDelegate {
    var onDownloadLink: (String) -> Void = { _ in }
    private var menuPoint = CGPoint.zero

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let p = convert(event.locationInWindow, from: nil)
        menuPoint = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        let item = NSMenuItem(title: "Download Audio", action: #selector(downloadLink), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func downloadLink() {
        let js = """
        (function(x, y) {
          for (const el of document.elementsFromPoint(x, y)) {
            const a = el.closest && el.closest('a[href]');
            if (a) return a.href;
          }
          return location.href;
        })(\(menuPoint.x), \(menuPoint.y))
        """
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let s = result as? String, let u = URL(string: s), YouTubeLink.isVideo(u) else { NSSound.beep(); return }
            self?.onDownloadLink(YouTubeLink.clean(u))
        }
    }

    // Open target=_blank links and sign-in pop-ups in this same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

struct YouTubeWebViewRep: NSViewRepresentable {
    let model: YouTubeBrowserModel

    func makeNSView(context: Context) -> YouTubeWebView {
        let v = YouTubeWebView(frame: .zero, configuration: makeBrowserConfiguration())
        v.uiDelegate = v
        v.allowsBackForwardNavigationGestures = true
        v.onDownloadLink = { [weak model] link in model?.onDownload(link) }
        model.attach(v)
        AdBlock.apply(to: v)
        model.home()
        return v
    }

    func updateNSView(_ v: YouTubeWebView, context: Context) {}
}

struct YouTubeBrowserView: View {
    @StateObject private var model: YouTubeBrowserModel
    let onClose: () -> Void

    init(onDownload: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        let m = YouTubeBrowserModel()
        m.onDownload = onDownload
        _model = StateObject(wrappedValue: m)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.webView?.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!model.canGoBack)
                Button { model.webView?.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!model.canGoForward)
                Button { model.home() } label: { Label("YouTube Home", systemImage: "house") }
                Button { model.webView?.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.purpleGlassIcon(30))
            .overlay(alignment: .trailing) { EmptyView() }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                Text(model.url?.host.map { $0 + (model.url?.path ?? "") } ?? "")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 360)
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 8) {
                    Button { model.toggleAdBlock() } label: {
                        Label(model.adBlock ? "Ad Block On" : "Ad Block Off",
                              systemImage: model.adBlock ? "shield.lefthalf.filled" : "shield.slash")
                    }
                    .help(model.adBlock ? "Ad blocking is on — click to turn off" : "Ad blocking is off — click to turn on")
                    .buttonStyle(.purpleGlass)
                    Button { model.downloadCurrent() } label: { Label("Download Audio", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(.purpleGlassProminent)
                        .disabled(!model.isVideo)
                        .help(model.isVideo ? "Download this video's audio as MP3" : "Open a video first")
                    Button("Done", action: onClose).keyboardShortcut(.cancelAction).buttonStyle(.purpleGlass)
                }
                .padding(.trailing, 10)
            }
            .padding(.vertical, 8)
            .background(.bar)

            Divider()
            YouTubeWebViewRep(model: model)
                .overlay(alignment: .top) {
                    if model.loading { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
                }

            Divider()
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2").foregroundStyle(.secondary)
                Text("Open a video and click Download Audio, or right-click any video → Download Audio. Sign in once and you'll stay signed in.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .frame(minWidth: 980, idealWidth: 1100, minHeight: 680, idealHeight: 780)
        .environment(\.appTheme, ThemeStore.shared.rendered)
        .environment(\.uiStyle, ThemeStore.shared.style)
        .tint(ThemeStore.shared.rendered.accent)
    }
}
