import SwiftUI
import AppKit

/// Checks GitHub for a newer release (at launch at most once a day, or from the app menu).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "silentrosehill/MP3Tagger"

    struct Release: Decodable { let tag_name: String; let html_url: String; let name: String? }

    @Published var alert: AlertInfo?
    struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let download: URL?
        let version: String?
    }

    /// Full version of this build, e.g. "3.16.0".
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func check(manual: Bool) {
        let d = UserDefaults.standard
        if !manual, let last = d.object(forKey: "updateLastCheck") as? Date, Date().timeIntervalSince(last) < 24 * 3600 { return }
        d.set(Date(), forKey: "updateLastCheck")
        Task {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let rel = try? JSONDecoder().decode(Release.self, from: data) else {
                if manual { alert = AlertInfo(title: "Couldn't check for updates", message: "GitHub didn't answer. Check your connection and try again.", download: nil, version: nil) }
                return
            }
            let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(latest, than: Self.current) {
                // automatic checks don't nag about a version you've already said "Later" to
                if !manual, d.string(forKey: "updateSkipped") == latest { return }
                alert = AlertInfo(title: "MP3 Tagger \(latest) is available",
                                  message: "You have \(Self.current). Download the new version from GitHub, unzip it and replace the app in Applications.",
                                  download: URL(string: rel.html_url), version: latest)
            } else if manual {
                alert = AlertInfo(title: "You're up to date", message: "MP3 Tagger \(Self.current) is the latest version.", download: nil, version: nil)
            }
        }
    }

    func later(_ info: AlertInfo) {
        if let v = info.version { UserDefaults.standard.set(v, forKey: "updateSkipped") }
    }

    /// "3.10.0" > "3.9.2" (numeric, part by part).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

extension View {
    /// The update alert, shown wherever the app's main window is.
    func updateAlert(_ updater: Updater) -> some View {
        alert(item: Binding(get: { updater.alert }, set: { updater.alert = $0 })) { info in
            if let url = info.download {
                return Alert(title: Text(info.title), message: Text(info.message),
                             primaryButton: .default(Text("Download")) { NSWorkspace.shared.open(url) },
                             secondaryButton: .cancel(Text("Later")) { updater.later(info) })
            }
            return Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
    }
}
