import SwiftUI
import AppKit
import ImageIO

/// App colors, all derived from one base color so any pick stays harmonious.
/// The default base (#B23AEE) reproduces the original purple palette from the app icon.
struct AppTheme: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double
    /// How strongly the sidebar is tinted (0 = plain see-through, 1 = full).
    var tintStrength: Double = 1

    static let purpleDefault = AppTheme(hex: 0xB23AEE)

    init(hue: Double, saturation: Double, brightness: Double, tintStrength: Double = 1) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness; self.tintStrength = tintStrength
    }

    init(hex: UInt32) {
        let c = NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        self.init(color: c)
    }

    init(color: NSColor) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        self.init(hue: Double(h), saturation: Double(s), brightness: Double(b))
    }

    private static func wrap(_ h: Double) -> Double { (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }
    private func c(_ dh: Double, s: Double, b: Double) -> Color {
        Color(hue: Self.wrap(hue + dh), saturation: min(max(s, 0), 1), brightness: min(max(b, 0), 1))
    }

    /// Main color (the original "purple").
    var purple: Color { c(0, s: saturation, b: brightness) }
    /// Deeper shade (the original "indigo").
    var indigo: Color { c(-0.07, s: saturation + 0.08, b: brightness * 0.77) }
    /// Warm highlight (the original "pink"): leans toward pink by at most 0.185 of the hue wheel,
    /// so purple gets its pink, orange/red get pink-red, blue gets violet, green gets yellow-green.
    var pink: Color {
        var toPink = 0.966 - hue
        toPink -= toPink.rounded()  // shortest way around the hue wheel
        return c(min(max(toPink, -0.185), 0.185), s: saturation * 0.77, b: 1)
    }
    /// Accent for selection, sliders and focus rings.
    var accent: Color { c(-0.03, s: saturation * 0.87, b: min(brightness + 0.03, 0.96)) }
    var base: Color { purple }

    /// Wash laid over the sidebar's see-through blur.
    var sidebarTint: LinearGradient {
        let k = tintStrength
        return LinearGradient(colors: [pink.opacity(0.16 * k), purple.opacity(0.22 * k), indigo.opacity(0.28 * k)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Three-stop gradient used for swatches.
    var swatch: LinearGradient {
        LinearGradient(colors: [pink, purple, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Picks the most prominent vivid color of a cover image. Mostly-grey covers give a graphite theme.
    nonisolated static func fromCover(_ data: Data) -> AppTheme? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary) else { return nil }
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: n, height: n))

        // Bucket pixels by hue, weighting vivid, mid-to-bright pixels most.
        let buckets = 36
        var score = [Double](repeating: 0, count: buckets)
        var sumX = [Double](repeating: 0, count: buckets), sumY = sumX, sumS = sumX, sumV = sumX
        var greyV = 0.0, greyHueX = 0.0, greyHueY = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            let v = mx, s = mx == 0 ? 0 : d / mx
            var h = 0.0
            if d > 0 {
                if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
                else if mx == g { h = (b - r) / d + 2 }
                else { h = (r - g) / d + 4 }
                h = (h / 6 + 1).truncatingRemainder(dividingBy: 1)
            }
            greyV += v
            let w = s * s * (v < 0.18 ? 0.05 : v)
            guard w > 0 else { continue }
            let k = min(Int(h * Double(buckets)), buckets - 1)
            score[k] += w
            sumX[k] += cos(h * 2 * .pi) * w; sumY[k] += sin(h * 2 * .pi) * w
            sumS[k] += s * w; sumV[k] += v * w
            greyHueX += cos(h * 2 * .pi) * d; greyHueY += sin(h * 2 * .pi) * d
        }
        let pixels = Double(n * n)
        // Merge each bucket with its neighbours so a hue split across two buckets still wins.
        var best = 0, bestScore = -1.0
        for k in 0..<buckets {
            let s3 = score[k] + score[(k + 1) % buckets] + score[(k + buckets - 1) % buckets]
            if s3 > bestScore { bestScore = s3; best = k }
        }
        if bestScore / pixels < 0.03 {
            let h = (atan2(greyHueY, greyHueX) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
            return AppTheme(hue: h, saturation: 0.08, brightness: min(max(greyV / pixels + 0.2, 0.5), 0.75))
        }
        var x = 0.0, y = 0.0, ss = 0.0, vv = 0.0, w = 0.0
        for k in [(best + buckets - 1) % buckets, best, (best + 1) % buckets] {
            x += sumX[k]; y += sumY[k]; ss += sumS[k]; vv += sumV[k]; w += score[k]
        }
        let hue = (atan2(y, x) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
        return AppTheme(hue: hue, saturation: min(max(ss / w, 0.45), 0.85), brightness: min(max(vv / w, 0.62), 0.95))
    }

    func sameColor(as o: AppTheme) -> Bool {
        abs(hue - o.hue) < 0.005 && abs(saturation - o.saturation) < 0.01 && abs(brightness - o.brightness) < 0.01
    }
}

/// Overall look. Only drawing changes between styles — sizes and positions stay identical.
enum UIStyle: String, Hashable {
    case glass, mavericks
}

/// What slides out of the mini player's cover while playing.
enum DiscKind: String, Hashable {
    case vinyl, cd
}

/// Colors for the Mavericks (OS X 10.9) skeuomorphic style.
enum Classic {
    static func c(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let windowTop = c(0xECECEC), windowBottom = c(0xDEDEDE)
    static let sidebarTop = c(0xE2E7ED), sidebarBottom = c(0xD2D9E2), sidebarEdge = c(0xB5BCC6)
    static let panelTop = c(0xFCFCFC), panelBottom = c(0xEAEAEA), panelBorder = c(0xB3B3B3)
    static let buttonTop = c(0xFFFFFF), buttonBottom = c(0xDCDCDC), buttonBorder = c(0x9C9C9C)
    static let pressedTop = c(0xC9C9C9), pressedBottom = c(0xE2E2E2)
    static let aquaTop = c(0x77B8FB), aquaMid = c(0x2C8AF4), aquaBottom = c(0x0B6BE8), aquaBorder = c(0x2556A8)
    static let lcdTop = c(0xF6F7F1), lcdBottom = c(0xE4E7DC), lcdBorder = c(0x9EA396)
    static let text = c(0x2B2B2B)
    /// Aqua blue theme used for sliders, selection and meters in this style.
    static let aqua = AppTheme(hex: 0x3F83F2)
}

/// The user's chosen theme, saved between launches.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    static let presets: [(name: String, theme: AppTheme)] = [
        ("Purple", .purpleDefault),
        ("Pink", AppTheme(hex: 0xEE3A9A)),
        ("Red", AppTheme(hex: 0xE5484D)),
        ("Orange", AppTheme(hex: 0xF07B2A)),
        ("Gold", AppTheme(hex: 0xD9A521)),
        ("Green", AppTheme(hex: 0x2FBF71)),
        ("Teal", AppTheme(hex: 0x1FB5B0)),
        ("Blue", AppTheme(hex: 0x3A7BEE)),
        ("Graphite", AppTheme(hue: 0.7, saturation: 0.08, brightness: 0.62)),
    ]

    @Published var theme: AppTheme {
        didSet {
            let d = UserDefaults.standard
            d.set(theme.hue, forKey: "themeHue"); d.set(theme.saturation, forKey: "themeSat")
            d.set(theme.brightness, forKey: "themeBri"); d.set(theme.tintStrength, forKey: "themeTint")
        }
    }

    @Published var style: UIStyle = UIStyle(rawValue: UserDefaults.standard.string(forKey: "uiStyle") ?? "") ?? .glass {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: "uiStyle")
            applyAppearance()
        }
    }

    /// Mavericks predates dark mode, so that style forces the light appearance — app-wide, via NSApp.
    /// (SwiftUI's per-view preferredColorScheme left parts of the window stuck in light mode after
    /// switching back to Liquid Glass, e.g. the translucent sidebar.)
    func applyAppearance() {
        NSApplication.shared.appearance = style == .mavericks ? NSAppearance(named: .aqua) : nil
    }

    @Published var disc: DiscKind = DiscKind(rawValue: UserDefaults.standard.string(forKey: "discKind") ?? "") ?? .vinyl {
        didSet { UserDefaults.standard.set(disc.rawValue, forKey: "discKind") }
    }

    /// Theme to render with: Mavericks uses classic Aqua blue; Liquid Glass uses the chosen color.
    var rendered: AppTheme {
        guard style == .mavericks else { return effective }
        var t = Classic.aqua
        t.tintStrength = theme.tintStrength
        return t
    }

    /// When on, colors follow the cover being viewed/edited instead of `theme`.
    @Published var matchCover: Bool = UserDefaults.standard.bool(forKey: "themeMatchCover") {
        didSet { UserDefaults.standard.set(matchCover, forKey: "themeMatchCover") }
    }
    /// Theme derived from the current cover (nil when there's no cover to follow).
    @Published private(set) var coverTheme: AppTheme?
    private var coverKey: Int?
    private var cache: [Int: AppTheme] = [:]

    /// What the app actually renders with.
    var effective: AppTheme {
        guard matchCover, var t = coverTheme else { return theme }
        t.tintStrength = theme.tintStrength
        return t
    }

    /// Call whenever the cover on screen changes (nil = nothing showing).
    func follow(cover data: Data?) {
        guard let data else {
            coverKey = nil
            withAnimation(.easeInOut(duration: 0.6)) { coverTheme = nil }
            return
        }
        let key = data.hashValue ^ data.count
        guard key != coverKey else { return }
        coverKey = key
        if let hit = cache[key] {
            withAnimation(.easeInOut(duration: 0.6)) { coverTheme = hit }
            return
        }
        Task.detached(priority: .userInitiated) {
            let t = AppTheme.fromCover(data)
            await MainActor.run {
                if let t { self.cache[key] = t }
                guard self.coverKey == key else { return }  // a newer cover took over
                withAnimation(.easeInOut(duration: 0.6)) { self.coverTheme = t }
            }
        }
    }

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: "themeHue") != nil {
            theme = AppTheme(hue: d.double(forKey: "themeHue"), saturation: d.double(forKey: "themeSat"),
                             brightness: d.double(forKey: "themeBri"),
                             tintStrength: d.object(forKey: "themeTint") as? Double ?? 1)
        } else {
            theme = .purpleDefault
        }
    }

    func apply(_ preset: AppTheme) {
        matchCover = false
        var t = preset
        t.tintStrength = theme.tintStrength
        theme = t
    }

    /// Binding for the custom color well; keeps the tint strength.
    var customColor: Binding<Color> {
        Binding(get: { self.theme.base },
                set: { new in
                    self.matchCover = false
                    var t = AppTheme(color: NSColor(new))
                    t.tintStrength = self.theme.tintStrength
                    self.theme = t
                })
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.purpleDefault
}

private struct UIStyleKey: EnvironmentKey {
    static let defaultValue = UIStyle.glass
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
    var uiStyle: UIStyle {
        get { self[UIStyleKey.self] }
        set { self[UIStyleKey.self] = newValue }
    }
}

enum Theme {
    static var rim: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.08), .white.opacity(0.35)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Frosted glass capsule in the theme color. `prominent` is the saturated version for the main action.
struct PurpleGlassButtonStyle: ButtonStyle {
    var prominent = false
    /// Round button sized for a single icon.
    var icon = false
    var iconSize: CGFloat = 40
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appTheme) private var theme
    @Environment(\.uiStyle) private var style

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        if style == .mavericks { return AnyView(classic(configuration, pressed: pressed)) }
        return AnyView(glass(configuration, pressed: pressed))
    }

    /// OS X Mavericks push button: grey gradient bevel, or glossy Aqua blue for the main action.
    private func classic(_ configuration: Configuration, pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: icon ? iconSize / 2 : 5, style: icon ? .circular : .continuous)
        let fill: [Color] = prominent
            ? (pressed ? [Classic.aquaBottom, Classic.aquaMid] : [Classic.aquaTop, Classic.aquaMid, Classic.aquaBottom])
            : (pressed ? [Classic.pressedTop, Classic.pressedBottom] : [Classic.buttonTop, Classic.buttonBottom])
        return configuration.label
            .font(icon ? .system(size: iconSize * 0.4, weight: .semibold) : .callout.weight(prominent ? .semibold : .medium))  // same weights as Liquid Glass → same sizes
            .foregroundStyle(prominent ? Color.white : Classic.text)
            .shadow(color: prominent ? .black.opacity(0.35) : .white.opacity(0.9), radius: 0, y: prominent ? -0.5 : 1)  // embossed text
            .padding(.horizontal, icon ? 0 : 14)
            .padding(.vertical, icon ? 0 : 6)
            .frame(width: icon ? iconSize : nil, height: icon ? iconSize : nil)
            .background {
                ZStack {
                    shape.fill(LinearGradient(colors: fill, startPoint: .top, endPoint: .bottom))
                    // top highlight line
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(prominent ? 0.55 : 0.95), .clear],
                                                      startPoint: .top, endPoint: .center), lineWidth: 1)
                        .padding(1)
                }
            }
            .overlay(shape.strokeBorder(prominent ? Classic.aquaBorder : Classic.buttonBorder, lineWidth: 1))
            .shadow(color: .black.opacity(pressed ? 0.05 : 0.18), radius: 0.5, y: pressed ? 0 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(shape)
    }

    private func glass(_ configuration: Configuration, pressed: Bool) -> some View {
        configuration.label
            .font(icon ? .system(size: iconSize * 0.4, weight: .semibold) : .callout.weight(prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, icon ? 0 : 14)
            .padding(.vertical, icon ? 0 : 6)
            .frame(width: icon ? iconSize : nil, height: icon ? iconSize : nil)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(LinearGradient(
                        colors: prominent ? [theme.purple.opacity(0.9), theme.indigo.opacity(0.95)]
                                          : [theme.purple.opacity(pressed ? 0.42 : 0.28), theme.indigo.opacity(pressed ? 0.36 : 0.22)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    // glossy top half
                    Capsule().fill(LinearGradient(colors: [.white.opacity(prominent ? 0.28 : 0.2), .clear],
                                                  startPoint: .top, endPoint: .center))
                }
            }
            .overlay(Capsule().strokeBorder(Theme.rim, lineWidth: 1))
            .shadow(color: theme.purple.opacity(prominent ? 0.45 : 0.25), radius: pressed ? 2 : 6, y: pressed ? 1 : 3)
            .scaleEffect(pressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PurpleGlassButtonStyle {
    static var purpleGlass: PurpleGlassButtonStyle { PurpleGlassButtonStyle() }
    static var purpleGlassProminent: PurpleGlassButtonStyle { PurpleGlassButtonStyle(prominent: true) }
    static var purpleGlassIcon: PurpleGlassButtonStyle { PurpleGlassButtonStyle(icon: true) }
    static func purpleGlassIcon(_ size: CGFloat) -> PurpleGlassButtonStyle { PurpleGlassButtonStyle(icon: true, iconSize: size) }
}

/// Segmented switch whose purple glass highlight slides between options.
struct GlassSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    /// Options shown as a compact icon (SF Symbol) instead of text; the title becomes the tooltip.
    var icons: [T: String] = [:]
    @Namespace private var ns
    @Environment(\.appTheme) private var theme
    @Environment(\.uiStyle) private var style

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let on = value == selection
                let icon = icons[value]
                let textCount = options.count - icons.count
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { selection = value }
                } label: {
                    Group {
                        if let icon { Image(systemName: icon) } else { Text(title) }
                    }
                        .font(.callout.weight(on ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(style == .mavericks ? AnyShapeStyle(Classic.text.opacity(on ? 1 : 0.75))
                                         : (on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)))
                        .shadow(color: style == .mavericks ? .white.opacity(0.8) : .clear, radius: 0, y: 1)
                        .padding(.horizontal, icon != nil ? 0 : (textCount > 2 ? 6 : 14))
                        .padding(.vertical, 5)
                        .frame(width: icon != nil ? 34 : nil)
                        .frame(maxWidth: icon != nil ? 34 : .infinity)
                        .background {
                            if on && style == .mavericks {
                                // pressed-in segment
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(LinearGradient(colors: [Classic.pressedTop, Classic.pressedBottom], startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.05)],
                                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1))
                                    .matchedGeometryEffect(id: "highlight", in: ns)
                            } else if on {
                                ZStack {
                                    Capsule().fill(LinearGradient(colors: [theme.purple.opacity(0.9), theme.indigo.opacity(0.9)],
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center))
                                }
                                .overlay(Capsule().strokeBorder(Theme.rim, lineWidth: 1))
                                .shadow(color: theme.purple.opacity(0.45), radius: 5, y: 2)
                                .matchedGeometryEffect(id: "highlight", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(title)
            }
        }
        .padding(3)
        .background {
            if style == .mavericks {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [Classic.buttonTop, Classic.buttonBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Classic.buttonBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 1)
            } else {
                Capsule().fill(.ultraThinMaterial)
                    .background(Capsule().fill(theme.purple.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Theme.rim.opacity(0.6), lineWidth: 1))
            }
        }
    }
}

/// Panel background that follows the style: frosted glass, or a light bevelled Mavericks panel
/// (`lcd` gives the iTunes-style display used by the mini player).
struct StyledPanel<Glass: View>: View {
    let cornerRadius: CGFloat
    var lcd = false
    @ViewBuilder let glass: () -> Glass
    @Environment(\.uiStyle) private var style

    var body: some View {
        if style == .mavericks {
            let shape = RoundedRectangle(cornerRadius: min(cornerRadius, 8), style: .continuous)
            shape
                .fill(LinearGradient(colors: lcd ? [Classic.lcdTop, Classic.lcdBottom] : [Classic.panelTop, Classic.panelBottom],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(lcd ? Classic.lcdBorder : Classic.panelBorder, lineWidth: 1))
                .overlay(shape.inset(by: 1).stroke(LinearGradient(colors: [.white.opacity(0.9), .clear],
                                                                  startPoint: .top, endPoint: .center), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
        } else {
            glass()
        }
    }
}

/// Popover for picking the app color: presets, a custom color, and sidebar tint strength.
struct ThemePicker: View {
    @ObservedObject var store: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Theme").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Style").font(.subheadline).foregroundStyle(.secondary)
                GlassSegmented(selection: Binding(get: { store.style },
                                                  set: { s in withAnimation(.easeInOut(duration: 0.35)) { store.style = s } }),
                               options: [(.glass, "Liquid Glass"), (.mavericks, "Mavericks")])
                if store.style == .mavericks {
                    Text("Classic OS X 10.9 look: Aqua buttons, light panels. Colors below apply to Liquid Glass.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Player disc").font(.subheadline).foregroundStyle(.secondary)
                GlassSegmented(selection: Binding(get: { store.disc },
                                                  set: { d in withAnimation(.easeInOut(duration: 0.3)) { store.disc = d } }),
                               options: [(.vinyl, "Vinyl"), (.cd, "CD")])
            }

            Divider()

            Toggle(isOn: Binding(get: { store.matchCover },
                                 set: { on in withAnimation(.easeInOut(duration: 0.4)) { store.matchCover = on } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Match album cover")
                    Text("Colors follow the cover you're viewing").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 10), count: 5), alignment: .leading, spacing: 10) {
                ForEach(ThemeStore.presets, id: \.name) { preset in
                    let selected = !store.matchCover && store.theme.sameColor(as: preset.theme)
                    Button {
                        withAnimation(.easeInOut(duration: 0.35)) { store.apply(preset.theme) }
                    } label: {
                        Circle()
                            .fill(preset.theme.swatch)
                            .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                                  startPoint: .top, endPoint: .center)))
                            .overlay(Circle().strokeBorder(Theme.rim, lineWidth: 1))
                            .overlay {
                                if selected {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.4), radius: 2)
                                }
                            }
                            .frame(width: 34, height: 34)
                            .shadow(color: preset.theme.purple.opacity(selected ? 0.7 : 0.35), radius: selected ? 7 : 3, y: 2)
                            .scaleEffect(selected ? 1.08 : 1)
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }

            Divider()

            HStack {
                Text("Custom color")
                Spacer()
                ColorPicker("Custom color", selection: store.customColor, supportsOpacity: false)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sidebar tint")
                    Spacer()
                    Text("\(Int(store.theme.tintStrength * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { store.theme.tintStrength },
                                      set: { store.theme.tintStrength = $0 }), in: 0...2)
            }

            Button("Reset to Purple") {
                withAnimation(.easeInOut(duration: 0.35)) { store.theme = .purpleDefault }
            }
            .buttonStyle(.purpleGlass)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 262)
        .environment(\.appTheme, store.rendered)
        .environment(\.uiStyle, store.style)
        .tint(store.rendered.accent)
    }
}
