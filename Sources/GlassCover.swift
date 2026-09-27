import SwiftUI
import AppKit

/// Drives the "liquid glass pour" transition when the cover art changes.
@MainActor
final class CoverFX: ObservableObject {
    /// Cover shown underneath while the new one pours in.
    @Published var previous: Data?
    @Published var showsPrevious = false
    /// Liquid reveal progress (springs slightly past 1 for a jelly settle).
    @Published var reveal: CGFloat = 1
    /// Specular sheen sweep progress.
    @Published var sheen: CGFloat = 1
    private var generation = 0

    func play(from old: Data?) {
        generation += 1
        let gen = generation
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            previous = old
            showsPrevious = true
            reveal = 0
            sheen = 0
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DispatchQueue.main.async {
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.3)) { self.reveal = 1; self.sheen = 1 }
            } else {
                withAnimation(.spring(response: 0.75, dampingFraction: 0.6)) { self.reveal = 1 }
                withAnimation(.easeInOut(duration: 0.95).delay(0.2)) { self.sheen = 1 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard self.generation == gen else { return }
            self.showsPrevious = false
            self.previous = nil
        }
    }
}

/// Square cover art that fills its frame, or a placeholder when there is none.
struct CoverArt: View {
    let data: Data?
    var hint: String? = nil
    /// Largest size it's shown at, for the cached decode.
    var points: CGFloat = 260
    var body: some View {
        if let data, let img = CoverImageCache.image(for: data, points: points) {
            Image(nsImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.86), Color(white: 0.74)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 10) {
                    Image(systemName: "music.note").font(.system(size: 64, weight: .semibold))
                    if let hint {
                        Label(hint, systemImage: "magnifyingglass").font(.callout.weight(.medium))
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

/// The editor's big cover: a glass slab that frosts on hover and "pours" new art in.
struct GlassCover: View {
    let data: Data?
    @ObservedObject var fx: CoverFX
    let targeted: Bool
    var size: CGFloat = 220
    @Environment(\.uiStyle) private var style

    var body: some View {
        let p = fx.reveal
        let clampedP = min(max(p, 0), 1)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let pool = size * 1.5  // circle big enough to cover the corners when fully revealed

        ZStack {
            // Old cover sinks and melts away beneath the liquid.
            if fx.showsPrevious {
                CoverArt(data: fx.previous)
                    .frame(width: size, height: size)
                    .blur(radius: 10 * clampedP, opaque: true)
                    .scaleEffect(1 - 0.06 * clampedP)
                    .brightness(-0.12 * clampedP)
            }

            // New cover spreads from the center, coming into focus as it settles.
            CoverArt(data: data, hint: "Search the web")
                .frame(width: size, height: size)
                .blur(radius: 18 * max(0, 1 - p), opaque: true)
                .scaleEffect(1.12 - 0.12 * p)
                .mask(Circle().frame(width: pool, height: pool).scaleEffect(max(p, 0.001)))

            // Glass lens riding the liquid's edge.
            Circle()
                .strokeBorder(
                    AngularGradient(colors: [.white.opacity(0.95), .white.opacity(0.15), .white.opacity(0.7),
                                             .white.opacity(0.1), .white.opacity(0.95)], center: .center),
                    lineWidth: 12)
                .frame(width: pool, height: pool)
                .scaleEffect(max(p, 0.001))
                .blur(radius: 2.5)
                .opacity(Double(sin(.pi * clampedP)) * 0.9)
                .blendMode(.plusLighter)

            // Specular sheen sweeping across the glass.
            LinearGradient(colors: [.clear, .white.opacity(0.5), .white.opacity(0.75), .white.opacity(0.5), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: size * 0.4, height: size * 2)
                .rotationEffect(.degrees(28))
                .offset(x: -size * 1.1 + size * 2.2 * fx.sheen)
                .blendMode(.plusLighter)

            // Frosted glass while an image is dragged over.
            if targeted {
                ZStack {
                    CoverArt(data: data).frame(width: size, height: size).blur(radius: 22, opaque: true)
                    Color.white.opacity(0.22)
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 36, weight: .medium))
                        Text("Drop to apply").font(.headline)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
                .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // Glass rim: catches light top-left and bottom-right, flares while the sheen passes.
        .overlay {
            if style == .mavericks {
                // framed like a photo: white mat with a thin grey edge
                shape.strokeBorder(.white, lineWidth: 5)
                    .overlay(shape.strokeBorder(Classic.panelBorder, lineWidth: 1))
            } else {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.15), .white.opacity(0.05), .white.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.5 + 3 * sin(.pi * fx.sheen))
            }
        }
        .shadow(color: .black.opacity(targeted ? 0.35 : 0.22), radius: targeted ? 22 : 14, y: targeted ? 12 : 7)
        .scaleEffect(targeted ? 1.04 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: targeted)
    }
}
