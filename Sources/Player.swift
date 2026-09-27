import SwiftUI
import AVFoundation

/// Plays one song at a time; tapping the same song again pauses/resumes it.
@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = Player()

    @Published private(set) var url: URL?
    @Published private(set) var isPlaying = false
    /// Info about the current song, for the Now Playing bar.
    @Published private(set) var nowTitle = ""
    @Published private(set) var nowArtist = ""
    @Published private(set) var nowCover: Data?
    private var player: AVAudioPlayer?

    /// Volume lives in `PlayerVolume` so dragging the slider doesn't redraw every song row.
    fileprivate func applyVolume(_ v: Double) { player?.volume = Float(v) }

    func stop() {
        player?.stop()
        player = nil
        url = nil
        isPlaying = false
        PlayerProgress.shared.reset()
        ThemeStore.shared.playbackChanged()
    }

    var currentTime: Double { player?.currentTime ?? 0 }
    var duration: Double { player?.duration ?? 0 }

    func seek(to t: Double) {
        guard let p = player else { return }
        p.currentTime = min(max(t, 0), max(p.duration - 0.05, 0))
        PlayerProgress.shared.tick()
    }

    func isPlaying(_ u: URL) -> Bool { isPlaying && url == u }

    /// Returns an error message if the file couldn't be played.
    @discardableResult
    func toggle(_ u: URL) -> String? {
        if url == u, let p = player {
            if p.isPlaying { p.pause(); isPlaying = false } else { SongFinder.shared.stopPreview(); p.play(); isPlaying = true }
            return nil
        }
        player?.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: u)
            SongFinder.shared.stopPreview()      // one thing playing at a time
            p.delegate = self
            p.volume = Float(PlayerVolume.shared.volume)
            p.play()
            let tag = try? ID3.read(url: u)
            nowTitle = tag.map { $0.title.isEmpty ? u.deletingPathExtension().lastPathComponent : $0.title }
                ?? u.deletingPathExtension().lastPathComponent
            nowArtist = tag?.artist ?? ""
            nowCover = tag?.cover
            VisualizerModel.shared.load(u, cover: tag?.cover)
            player = p
            url = u
            isPlaying = true
            PlayerProgress.shared.start()
            ThemeStore.shared.playbackChanged()
            return nil
        } catch {
            player = nil
            url = nil
            isPlaying = false
            return "Couldn't play \(u.lastPathComponent)"
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.url = nil
            self.player = nil
            PlayerProgress.shared.reset()
            ThemeStore.shared.playbackChanged()
        }
    }
}

/// Playback position for the seek slider. Kept apart from `Player` so its 4×-a-second ticks only
/// redraw the mini player, not every song row.
@MainActor
final class PlayerProgress: ObservableObject {
    static let shared = PlayerProgress()
    @Published var current: Double = 0
    @Published private(set) var duration: Double = 0
    /// While the user drags the slider, the timer doesn't move the thumb.
    var scrubbing = false
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { PlayerProgress.shared.tick() }
        }
    }

    func tick() {
        guard !scrubbing else { return }
        current = Player.shared.currentTime
        duration = Player.shared.duration
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        current = 0
        duration = 0
        scrubbing = false
    }

    static func format(_ t: Double) -> String {
        let s = Int(max(t, 0).rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// App playback volume (0...1), remembered between launches.
@MainActor
final class PlayerVolume: ObservableObject {
    static let shared = PlayerVolume()
    @Published var volume: Double = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.8 {
        didSet {
            Player.shared.applyVolume(volume)
            SongFinder.shared.setPreviewVolume(volume)
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    private var volumeBeforeMute = 0.8

    func toggleMute() {
        if volume > 0 { volumeBeforeMute = volume; volume = 0 } else { volume = max(volumeBeforeMute, 0.1) }
    }
}

final class HoverState: ObservableObject {
    @Published var on = false
}

/// Small cover that doubles as a play/pause button, with a glass control on hover.
struct PlayableThumb: View {
    let url: URL
    let data: Data?
    var size: CGFloat = 32
    var onError: (String) -> Void = { _ in }
    @ObservedObject private var player = Player.shared
    @StateObject private var hover = HoverState()
    @Environment(\.appTheme) private var theme
    @Environment(\.uiStyle) private var style

    var body: some View {
        let current = player.url == url
        let playing = player.isPlaying(url)
        Button {
            if let err = player.toggle(url) { onError(err) }
        } label: {
            ZStack {
                CoverThumb(data: data, size: size)
                if hover.on || current {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(style == .mavericks
                            ? LinearGradient(colors: [Classic.c(0x5C5C5C), Classic.c(0x1C1C1C)], startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [theme.purple.opacity(0.55), theme.indigo.opacity(0.6)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(Circle().strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.1)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75))
                        .frame(width: size * 0.7, height: size * 0.7)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    Group {
                        if playing && !hover.on {
                            Image(systemName: "speaker.wave.2.fill")
                                .symbolEffect(.variableColor.iterative, isActive: true)
                        } else {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                        }
                    }
                    .font(.system(size: size * 0.28, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover.on)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: current)
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(playing ? "Pause" : "Play")
    }
}

/// Where the floating player sits; it snaps to the nearest corner after a drag.
@MainActor
final class PiPState: ObservableObject {
    enum Corner: String { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    @Published var corner: Corner = Corner(rawValue: UserDefaults.standard.string(forKey: "pipCorner") ?? "") ?? .bottomTrailing {
        didSet { UserDefaults.standard.set(corner.rawValue, forKey: "pipCorner") }
    }
    @Published var drag: CGSize = .zero
    @Published var dragging = false
    @Published var size = CGSize(width: 380, height: 130)
    /// The slide-out volume slider.
    @Published var volumeOpen = false
    private var volumeGeneration = 0
    private var holdingVolume = false

    func toggleVolume() {
        volumeOpen.toggle()
        if volumeOpen { touchVolume() }
    }

    /// Keeps the slider open while it's being used; closes it ~3 s after the last touch.
    func touchVolume(holding: Bool? = nil) {
        if let holding { holdingVolume = holding }
        volumeGeneration += 1
        let gen = volumeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard gen == self.volumeGeneration, !self.holdingVolume else { return }
            self.volumeOpen = false
        }
    }

    static let margin: CGFloat = 16

    /// Center of the player when resting in `corner` inside a container of `bounds`.
    func center(for corner: Corner, in bounds: CGSize) -> CGPoint {
        let m = Self.margin
        let left = corner == .topLeading || corner == .bottomLeading
        let top = corner == .topLeading || corner == .topTrailing
        return CGPoint(x: left ? m + size.width / 2 : bounds.width - m - size.width / 2,
                       y: top ? m + size.height / 2 : bounds.height - m - size.height / 2)
    }

    func dragGesture(in bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                self.dragging = true
                self.drag = v.translation
            }
            .onEnded { v in
                // Fling-aware: use where the throw would land, then snap to that quadrant's corner.
                let start = self.center(for: self.corner, in: bounds)
                let land = CGPoint(x: start.x + v.predictedEndTranslation.width, y: start.y + v.predictedEndTranslation.height)
                let left = land.x < bounds.width / 2, top = land.y < bounds.height / 2
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                    self.corner = top ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)
                    self.drag = .zero
                    self.dragging = false
                }
            }
    }
}

/// Picture-in-picture layer: the Now Playing bar floating over the window, draggable between corners.
struct FloatingPlayer: View {
    @ObservedObject private var player = Player.shared
    @StateObject private var pip = PiPState()

    var body: some View {
        GeometryReader { geo in
            if player.url != nil {
                let c = pip.center(for: pip.corner, in: geo.size)
                NowPlayingBar(pip: pip, bounds: geo.size)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { pip.size = g.size }
                            .onChange(of: g.size) { _, new in pip.size = new }
                    })
                    .scaleEffect(pip.dragging ? 1.04 : 1)
                    .shadow(color: .black.opacity(pip.dragging ? 0.35 : 0), radius: 24, y: 14)
                    .position(x: c.x + pip.drag.width, y: c.y + pip.drag.height)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.url)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pip.dragging)
    }
}

/// Glass mini player. Drag it by the grab handle or the cover/title area.
struct NowPlayingBar: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var vol = PlayerVolume.shared
    @ObservedObject private var progress = PlayerProgress.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject var pip: PiPState
    let bounds: CGSize
    @Environment(\.appTheme) private var theme
    @Environment(\.uiStyle) private var style

    /// Horizontal volume slider that slides out to the left of the volume button.
    private var volumePill: some View {
        HStack(spacing: 8) {
            Button { vol.toggleMute(); pip.touchVolume() } label: {
                Image(systemName: vol.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(vol.volume == 0 ? "Unmute" : "Mute")
            Slider(value: Binding(get: { vol.volume }, set: { vol.volume = $0; pip.touchVolume() }), in: 0...1) { editing in
                pip.touchVolume(holding: editing)
            }
            .controlSize(.small)
            .frame(width: 120)
            Text("\(Int(vol.volume * 100))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            StyledPanel(cornerRadius: 16) {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(Color.black.opacity(0.45))  // solid enough to hide the title behind it
                    Capsule().fill(LinearGradient(colors: [theme.purple.opacity(0.55), theme.indigo.opacity(0.6)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay(Capsule().strokeBorder(Theme.rim, lineWidth: 1))
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .fixedSize()
    }

    private var speakerIcon: String {
        switch vol.volume {
        case 0: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let url = player.url {
                VStack(spacing: 10) {
                    // grab handle
                    Capsule().fill(.white.opacity(pip.dragging ? 0.7 : 0.35))
                        .frame(width: 36, height: 5)
                        .padding(.vertical, 3).padding(.horizontal, 40)
                        .contentShape(Rectangle())
                        .gesture(pip.dragGesture(in: bounds))
                        .padding(.top, -4)
                        .padding(.bottom, -6)
                    let cover: CGFloat = 72
                    let spinning = player.isPlaying
                    HStack(spacing: 10) {
                        // Cover with a record that slides out while playing
                        ZStack(alignment: .leading) {
                            Group {
                                if themeStore.disc == .cd {
                                    CompactDisc(size: cover - 4, spinning: spinning)
                                } else {
                                    VinylDisc(label: player.nowCover, size: cover - 4, spinning: spinning)
                                }
                            }
                                .offset(x: spinning ? 34 : 2)
                            CoverThumb(data: player.nowCover, size: cover)
                                .shadow(color: .black.opacity(0.35), radius: 4, x: 2, y: 1)
                        }
                        .frame(width: cover + (spinning ? 32 : 0), height: cover, alignment: .leading)

                        VStack(alignment: .leading, spacing: 3) {
                            MarqueeText(text: player.nowTitle, font: .body.weight(.semibold))
                            MarqueeText(text: player.nowArtist.isEmpty ? "Unknown artist" : player.nowArtist, font: .callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        // Dynamic Island-style visualizer, moving with the song's real frequencies
                        AudioBars(playing: spinning, height: 24)
                            .padding(.trailing, 6)
                    }
                    .animation(.spring(response: 0.6, dampingFraction: 0.78), value: spinning)
                    .contentShape(Rectangle())
                    .gesture(pip.dragGesture(in: bounds))
                    .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .help("Drag to move the player")

                    // Play/pause · song position (drag to skip through) · volume
                    HStack(spacing: 8) {
                        Button { player.toggle(url) } label: {
                            Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .help(player.isPlaying ? "Pause" : "Play")

                        Text(PlayerProgress.format(progress.current))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        Slider(value: $progress.current, in: 0...max(progress.duration, 1)) { editing in
                            progress.scrubbing = editing
                            if !editing { Player.shared.seek(to: progress.current) }
                        }
                        .controlSize(.small)
                        .disabled(progress.duration <= 0)
                        .help("Drag to skip through the song")
                        Text("−" + PlayerProgress.format(progress.duration - progress.current))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)

                        // Volume: click to slide out a horizontal slider
                        Button { pip.toggleVolume() } label: {
                            Label("Volume", systemImage: speakerIcon)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .help("Volume \(Int(vol.volume * 100))%")
                        .overlay(alignment: .trailing) {
                            if pip.volumeOpen {
                                volumePill
                                    .offset(x: -32)
                                    .transition(.scale(scale: 0.2, anchor: .trailing).combined(with: .opacity))
                            }
                        }
                        .zIndex(1)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.purpleGlassIcon(26))
                    .animation(.spring(response: 0.35, dampingFraction: 0.78), value: pip.volumeOpen)
                }
                .padding(12)
                .background {
                    StyledPanel(cornerRadius: 16, lcd: true) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(LinearGradient(
                                colors: [theme.purple.opacity(0.28), theme.indigo.opacity(0.32)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.rim, lineWidth: 1))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Close: stops the song and hides the mini player
                    Button { player.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.black.opacity(0.3)))
                            .overlay(Circle().strokeBorder(Theme.rim, lineWidth: 0.8))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close the player")
                    .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    // Close: stops the song and hides the mini player
                    Button { player.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.black.opacity(0.3)))
                            .overlay(Circle().strokeBorder(Theme.rim, lineWidth: 0.8))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close the player")
                    .padding(8)
                }
                .shadow(color: style == .mavericks ? .black.opacity(0.25) : theme.purple.opacity(0.3), radius: 10, y: 4)
            }
        }
        .frame(width: 380)
    }
}

final class MarqueeMeasure: ObservableObject {
    @Published var textWidth: CGFloat = 0
    @Published var boxWidth: CGFloat = 0
    /// When scrolling (re)started, so each hover begins with the text at rest.
    var start = Date()
}

/// One-line text that scrolls like a ticker when it doesn't fit.
struct MarqueeText: View {
    let text: String
    let font: Font
    /// When false, a long title is simply truncated (sidebar rows scroll only on hover/selection).
    var active = true
    @StateObject private var m = MarqueeMeasure()

    private let speed: Double = 28       // points per second
    private let gap: CGFloat = 36        // space before the text repeats
    private let pause: Double = 1.8      // rest at the start of each loop

    var body: some View {
        // Any overflow at all makes the text truncate, so even half a point must scroll.
        let overflows = m.boxWidth > 0 && m.textWidth - m.boxWidth > 0.01
        let scrolling = overflows && active
        // A truncating copy sizes the box to the space available; the visible text rides in an
        // overlay so the full-length ticker never widens the layout.
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if scrolling {
                    TimelineView(.animation) { ctx in
                        let distance = Double(m.textWidth + gap)
                        let cycle = max(ctx.date.timeIntervalSince(m.start), 0).truncatingRemainder(dividingBy: distance / speed + pause)
                        let offset = cycle < pause ? 0 : (cycle - pause) * speed
                        HStack(spacing: gap) { Text(text); Text(text) }
                            .font(font)
                            .fixedSize()
                            .offset(x: -offset)
                    }
                } else {
                    Text(text).font(font).lineLimit(1)
                }
            }
        .clipped()
        .onChange(of: active) { _, on in if on { m.start = Date() } }
        .mask {
            if scrolling {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                       .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
            } else {
                Rectangle()
            }
        }
        // Re-measure whenever the space changes (e.g. the record sliding out narrows the title).
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in m.boxWidth = w }
        .background(
            Text(text).font(font).fixedSize().hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in m.textWidth = w }
        )
    }
}

/// A vinyl record: grooves, the song's cover as the centre label, and a fixed light reflection.
/// Spins at 33⅓ RPM in step with the song's position, so it stops when paused and jumps when you skip.
struct VinylDisc: View {
    let label: Data?
    let size: CGFloat
    let spinning: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !spinning)) { _ in
            record.rotationEffect(.degrees(Player.shared.currentTime * 200))  // 33⅓ RPM = 200°/s
        }
        .overlay(reflection)
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.4), radius: 3, x: 1, y: 1)
    }

    private var record: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.13), Color(white: 0.04)], center: .center,
                                         startRadius: 0, endRadius: size / 2))
            ForEach(0..<7, id: \.self) { i in
                Circle().stroke(.white.opacity(i % 2 == 0 ? 0.07 : 0.04), lineWidth: 0.6)
                    .padding(size * (0.05 + CGFloat(i) * 0.042))
            }
            Group {
                if let label, let img = CoverImageCache.image(for: label, points: size * 0.38) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [theme.pink, theme.purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: size * 0.38, height: size * 0.38)
            .clipShape(Circle())
            Circle().fill(Color(white: 0.05)).frame(width: 4, height: 4)  // spindle hole
        }
    }

    /// Stays still while the record turns underneath, like light on a real disc.
    private var reflection: some View {
        Circle()
            .fill(AngularGradient(colors: [.clear, .white.opacity(0.14), .clear, .clear, .white.opacity(0.1), .clear, .clear],
                                  center: .center, angle: .degrees(-30)))
            .allowsHitTesting(false)
    }
}

/// A CD seen from its shiny side, spinning at real audio-CD speed (see `spinAngle`), with Yeezus-style
/// reflections that stay fixed to the light. Spin follows the song.
struct CompactDisc: View {
    let size: CGFloat
    let spinning: Bool

    // Real CD proportions (120 mm disc): 15 mm hole, clear hub out to ~33 mm, data from ~46 mm.
    private var hole: CGFloat { size * 0.125 }
    private var hub: CGFloat { size * 0.28 }
    private var data: CGFloat { size * 0.38 }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !spinning)) { _ in
            let t = Player.shared.currentTime
            let spin = Self.spinAngle(at: t)
            ZStack {
                silver
                reflections(t)
                turningDetails.rotationEffect(.degrees(spin))
                hubRing.rotationEffect(.degrees(spin))
            }
            .mask(holeMask)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 3, x: 1, y: 1)
    }

    /// Degrees turned after `t` seconds, like a real audio CD: constant linear velocity (1.3 m/s) reading
    /// outward from r = 25 mm along a 1.6 µm spiral. That's ~500 RPM at the start, slowing as the track goes on.
    /// Integrating dθ = v/r dt along the spiral gives θ = 2π (r − r₀) / pitch.
    static func spinAngle(at t: Double) -> Double {
        let v = 1.3, r0 = 0.025, pitch = 1.6e-6
        let r = (r0 * r0 + v * pitch * max(t, 0) / .pi).squareRoot()
        return ((r - r0) / pitch * 360).truncatingRemainder(dividingBy: 360)
    }

    private func c(_ hex: UInt32) -> Color { Classic.c(hex) }

    /// Brushed-aluminium base: slightly brighter bands toward the edge.
    private var silver: some View {
        Circle().fill(RadialGradient(stops: [
            .init(color: c(0xD9DDE3), location: 0.0), .init(color: c(0xEEF0F3), location: 0.40),
            .init(color: c(0xC4C9D1), location: 0.62), .init(color: c(0xE4E7EB), location: 0.82),
            .init(color: c(0xB3B8C0), location: 1.0)],
            center: .center, startRadius: 0, endRadius: size / 2))
    }

    /// Yeezus-cover reflections: a high-contrast "bow tie". Two bright white/icy wedges face two dark
    /// brown-black wedges, with thin rainbow fringes (green, cyan / orange, yellow) where they meet.
    /// Like a real disc, the pattern stays put where the light hits and only shimmers while the disc turns underneath.
    private static let bowTie: [Gradient.Stop] = {
        // one half-turn; the other half mirrors it, like light across a real disc
        let half: [(UInt32, Double)] = [
            (0xFFFFFF, 0.00), (0xE4FAFD, 0.05), (0x7FE0EC, 0.090), (0x4CC48C, 0.115), (0x2F3A2C, 0.135),
            (0x2A1F1C, 0.170), (0x171213, 0.250), (0x2B1D27, 0.320), (0x5A2E3C, 0.345),
            (0xE0875C, 0.370), (0xF4DC8E, 0.395), (0xFBF6E4, 0.430), (0xFFFFFF, 0.50)]
        let stops = half.map { Gradient.Stop(color: Classic.c($0.0), location: $0.1 / 1) }
        return stops.map { .init(color: $0.color, location: $0.location) }
            + stops.dropFirst().map { .init(color: $0.color, location: $0.location + 0.5) }
    }()

    private struct Glint { let base, speed, width, drift, phase: Double; let tint: Color; let strength: Double }
    private var glints: [Glint] { [
        Glint(base: 8,   speed: 1.00, width: 0.012, drift: 12, phase: 0.0, tint: c(0x5FE3F5), strength: 0.9), // the thin cyan streak
        Glint(base: 30,  speed: 1.15, width: 0.04,  drift: 30, phase: 1.7, tint: .white,     strength: 0.8),
        Glint(base: 140, speed: 0.85, width: 0.03,  drift: 35, phase: 3.1, tint: .white,     strength: 0.6),
        Glint(base: 250, speed: 1.30, width: 0.02,  drift: 25, phase: 4.4, tint: c(0xB7F0C8), strength: 0.5), // mint
        Glint(base: 300, speed: 0.75, width: 0.03,  drift: 40, phase: 2.5, tint: c(0xF6C7A0), strength: 0.5), // peach
    ] }

    private func reflections(_ t: Double) -> some View {
        // Fixed to the light like on a real disc: only a slight wobble and shimmer as it spins.
        let wobble = sin(t * 2.3) * 7 + sin(t * 5.1) * 2.5
        return ZStack {
            Circle().fill(AngularGradient(stops: Self.bowTie, center: .center, angle: .degrees(160 + wobble)))
                .hueRotation(.degrees(sin(t * 1.3) * 10))            // fringes shift colour a little
            ForEach(glints.indices, id: \.self) { i in
                let g = glints[i]
                let angle = g.base + wobble + sin(t * 1.1 + g.phase) * 3
                let shimmer = 0.75 + 0.25 * sin(t * 3.7 + g.phase)
                Circle()
                    .fill(AngularGradient(stops: Self.lobes(width: g.width, color: g.tint), center: .center,
                                          angle: .degrees(angle)))
                    .blendMode(.screen)
                    .opacity(g.strength * shimmer)
            }
            // clear plastic rim at the very edge
            Circle().strokeBorder(c(0xCFE6EE).opacity(0.55), lineWidth: max(1, size * 0.02))
        }
        .mask(ring(inner: data, outer: size))
    }

    /// A soft streak and its mirror image across the hole (reflections on a disc come in pairs).
    private static func lobes(width w: Double, color: Color) -> [Gradient.Stop] {
        func lobe(_ at: Double) -> [Gradient.Stop] {
            [.init(color: color.opacity(0), location: at - w), .init(color: color, location: at),
             .init(color: color.opacity(0), location: at + w)]
        }
        return [.init(color: color.opacity(0), location: 0)] + lobe(0.25) + lobe(0.75) + [.init(color: color.opacity(0), location: 1)]
    }

    /// Things printed/pressed into the disc, so the turning is visible: faint track rings and the
    /// ring of small print near the edge (dashes stand in for the text at this size).
    private var turningDetails: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Circle().stroke(.white.opacity(0.06), lineWidth: 0.5)
                    .frame(width: data + (size - data) * CGFloat(i) / 6, height: data + (size - data) * CGFloat(i) / 6)
            }
            Circle().trim(from: 0.02, to: 0.9)
                .stroke(Color(white: 0.4).opacity(0.45),
                        style: StrokeStyle(lineWidth: max(0.6, size * 0.01), dash: [max(0.8, size * 0.012), max(0.6, size * 0.007)]))
                .frame(width: size * 0.9, height: size * 0.9)
        }
    }

    /// Clear plastic hub with its stacking ridges, inside a black ring (like the Yeezus disc).
    private var hubRing: some View {
        ZStack {
            Circle().fill(Color(white: 0.08)).frame(width: data, height: data)
            Circle().fill(c(0xE8ECEF).opacity(0.85)).frame(width: data * 0.86, height: data * 0.86)
            Circle().stroke(.white, lineWidth: 0.8).frame(width: data * 0.72, height: data * 0.72)
            ForEach(0..<8, id: \.self) { i in
                Capsule().fill(Color(white: 0.6).opacity(0.5))
                    .frame(width: data * 0.12, height: max(0.6, size * 0.01))
                    .offset(x: data * 0.26)
                    .rotationEffect(.degrees(Double(i) * 45))
            }
        }
    }

    private func ring(inner: CGFloat, outer: CGFloat) -> some View {
        ZStack {
            Circle().frame(width: outer, height: outer)
            Circle().frame(width: inner, height: inner).blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    /// Whole disc with a see-through centre hole.
    private var holeMask: some View { ring(inner: hole, outer: size) }
}
