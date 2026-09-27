import SwiftUI

/// The ⓘ toolbar popover: what each tab and button does. Click a tab to jump to it.
struct InfoPanel: View {
    @ObservedObject var lib: Library
    @Environment(\.appTheme) private var theme

    private struct Section: Identifiable {
        let id = UUID()
        let tab: SidebarTab?
        let icon: String
        let title: String
        let points: [String]
    }

    private let sections: [Section] = [
        Section(tab: .files, icon: "music.note.list", title: "Files", points: [
            "Drop MP3s or folders, or press +",
            "Edit title, artist, album, year, track and genre",
            "Cover: drag an image on, pick a file, or search albums and the web",
            "✨ Official Tags: fill everything in from Apple Music",
            "Loudness: match Spotify (−14 LUFS), lossless and undoable",
            "Trim: cut a talking intro/outro (play it, click Here), no re-encoding",
            "Save, Save As, Apply Album & Cover to All · ⌘Z undoes unsaved changes",
            "Rename files to “Artist - Title” (under the path, or right-click)",
        ]),
        Section(tab: .history, icon: "clock.arrow.circlepath", title: "History", points: [
            "Every song you've saved, newest first",
            "Click a cover to play it",
        ]),
        Section(tab: .find, icon: "wand.and.stars", title: "Auto", points: [
            "Type a song and artist to find it on YouTube",
            "Click a thumbnail to hear the first 30 seconds",
            "Download: official tags + cover, Spotify loudness, then the editor",
        ]),
        Section(tab: .download, icon: "arrow.down.circle", title: "Download (⬇︎)", points: [
            "Paste a video link, or browse YouTube in the app (with ad blocker)",
            "Pick the quality and folder, and update yt-dlp if downloads fail",
        ]),
        Section(tab: .changelog, icon: "list.bullet.rectangle.portrait", title: "Changelog", points: [
            "What changed in every version",
            "New versions: the app checks GitHub daily, or MP3 Tagger menu → Check for Updates…",
        ]),
        Section(tab: nil, icon: "play.circle", title: "Mini player", points: [
            "Drag it anywhere; it snaps to the corners",
            "Vinyl or CD, visualizer, seek bar, volume, ✕ to close",
            "Plays through the list: ⏮ ⏭, or Space = play/pause, ← → = previous/next",
        ]),
        Section(tab: nil, icon: "paintpalette", title: "Theme (🎨)", points: [
            "Liquid Glass or Mavericks style, vinyl or CD",
            "Colors, custom color, or match the album cover",
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's where").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { s in row(s) }
                }
            }
            .frame(maxHeight: 600)
            Text("Click a tab to go there.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 390)
    }

    @ViewBuilder private func row(_ s: Section) -> some View {
        if let t = s.tab {
            Button { lib.tab = t; lib.showInfo = false } label: { rowContent(s) }
                .buttonStyle(.plain)
                .help("Go to \(s.title)")
        } else {
            rowContent(s)      // not a tab: nothing to jump to
        }
    }

    private func rowContent(_ s: Section) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.pink)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.subheadline.weight(.semibold))
                ForEach(s.points, id: \.self) { p in
                    Text("• " + p).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(s.tab != nil && lib.tab == s.tab ? theme.purple.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }
}
