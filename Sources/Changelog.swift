import SwiftUI

/// One version from CHANGELOG.md (bundled in the app, so the tab always matches the file).
struct ChangelogEntry: Identifiable {
    let version: String
    let build: String
    let changes: [String]
    var id: String { version }
    var isFix: Bool { changes.allSatisfy { $0.hasPrefix("Fix") } }
}

enum Changelog {
    /// Parses "## 2.4.1 (build 26)" / "## 2.3.0 (24)" headings and "- " bullets.
    static let entries: [ChangelogEntry] = {
        // MP3TAGGER_CHANGELOG lets tests point at the file directly.
        let override = ProcessInfo.processInfo.environment["MP3TAGGER_CHANGELOG"].map { URL(fileURLWithPath: $0) }
        guard let url = override ?? Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [ChangelogEntry] = []
        var version: String?, build = "", changes: [String] = []
        func flush() { if let v = version { result.append(ChangelogEntry(version: v, build: build, changes: changes)) } }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                let head = line.dropFirst(3)
                if let open = head.firstIndex(of: "("), let close = head.lastIndex(of: ")"), open < close {
                    version = head[..<open].trimmingCharacters(in: .whitespaces)
                    build = head[head.index(after: open)..<close].replacingOccurrences(of: "build ", with: "")
                } else {
                    version = String(head); build = ""
                }
                changes = []
            } else if line.hasPrefix("- "), version != nil {
                changes.append(String(line.dropFirst(2)))
            }
        }
        flush()
        return result
    }()

    static var installed: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

struct ChangelogSidebar: View {
    @ObservedObject var lib: Library

    var body: some View {
        List(Changelog.entries, selection: $lib.changelogSelection) { e in
            HStack {
                Image(systemName: e.isFix ? "wrench.adjustable" : "sparkles")
                    .foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Version \(e.version)").lineLimit(1)
                    Text(e.changes.first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if e.version == Changelog.installed {
                    Text("Installed").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.tint.opacity(0.35)))
                }
            }
            .tag(e.id)
        }
        .scrollContentBackground(.hidden)
    }
}

struct ChangelogView: View {
    @ObservedObject var lib: Library
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Changelog").font(.title2.bold())
                        Text("Every update to MP3 Tagger, newest first. You're running \(Changelog.installed).")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)

                    if Changelog.entries.isEmpty {
                        Text("The changelog isn't available in this build.").foregroundStyle(.secondary)
                    }
                    ForEach(Changelog.entries) { e in
                        card(e).id(e.id)
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: lib.changelogSelection) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .onAppear { ThemeStore.shared.followNothing() }
    }

    private func card(_ e: ChangelogEntry) -> some View {
        let current = e.version == Changelog.installed
        let selected = lib.changelogSelection == e.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(e.version).font(.title3.bold())
                if !e.build.isEmpty { Text("build \(e.build)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if current {
                    Label("Installed", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(LinearGradient(colors: [theme.purple, theme.indigo],
                                                                  startPoint: .leading, endPoint: .trailing)))
                }
            }
            ForEach(e.changes, id: \.self) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: c.hasPrefix("Fix") ? "wrench.adjustable" : "sparkle")
                        .font(.caption).foregroundStyle(theme.pink)
                    Text(c).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            StyledPanel(cornerRadius: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [theme.purple.opacity(current ? 0.22 : 0.1), theme.indigo.opacity(current ? 0.24 : 0.12)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Theme.rim.opacity(0.6)), lineWidth: selected ? 2 : 1))
    }
}
