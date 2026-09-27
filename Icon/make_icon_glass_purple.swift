// Renders the "Liquid Glass" variant of the MP3 Tagger icon (purple palette) to a 1024×1024 PNG.
// Usage: swiftc make_icon_glass_purple.swift -o make_icon_glass_purple && ./make_icon_glass_purple out.png
import AppKit
import CoreImage

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let ci = CIContext(options: [.workingColorSpace: cs])

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { rgb(0xFFFFFF, a) }
func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

let green = 0x1ED760 as UInt32, deepGreen = 0x0F7A35 as UInt32

/// Blurred snapshot of everything drawn so far (the "backdrop" glass refracts).
func backdrop(blur: Double) -> CGImage {
    let img = CIImage(cgImage: ctx.makeImage()!)
    let out = img.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: img.extent)
    return ci.createCGImage(out, from: img.extent)!
}

/// Draws a Liquid Glass slab: soft shadow, refracted + frosted backdrop, tint, specular rim.
func glass(_ path: CGPath, tint: CGColor, blur: Double = 22, refraction: CGFloat = 1.08, rim: CGFloat = 5, eo: Bool = false) {
    let rule: CGPathFillRule = eo ? .evenOdd : .winding
    let b = path.boundingBox
    let bg = backdrop(blur: blur)

    // drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 50, color: rgb(0x000000, 0.55))
    ctx.addPath(path); ctx.setFillColor(rgb(0x000000)); ctx.fillPath(using: rule)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip(using: rule)
    // refraction: backdrop slightly magnified around the slab's center
    ctx.saveGState()
    ctx.translateBy(x: b.midX, y: b.midY); ctx.scaleBy(x: refraction, y: refraction); ctx.translateBy(x: -b.midX, y: -b.midY)
    ctx.draw(bg, in: CGRect(x: 0, y: 0, width: S, height: S))
    ctx.restoreGState()
    // tint + frosting
    ctx.setFillColor(tint); ctx.fill(b)
    ctx.drawLinearGradient(gradient([white(0.24), white(0.03), white(0.0), white(0.08)], [0, 0.45, 0.7, 1]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    // inner edge glow (light caught inside the thickness of the glass)
    ctx.setShadow(offset: .zero, blur: 30, color: white(0.55))
    ctx.addRect(b.insetBy(dx: -200, dy: -200)); ctx.addPath(path)
    ctx.setFillColor(white(1)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // specular rim: bright top-left and bottom-right, fading in between
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(rim); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([white(0.95), white(0.25), white(0.05), white(0.25), white(0.75)], [0, 0.3, 0.5, 0.7, 1]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    ctx.restoreGState()
}

// MARK: Background squircle
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x0A0A0A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFF6A88), rgb(0xB23AEE), rgb(0x4B1FB8)]),
                       start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
// soft top highlight + a warm glow behind the cover for the glass to pick up
ctx.drawRadialGradient(gradient([white(0.28), white(0)]), startCenter: CGPoint(x: 330, y: 880), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: 880), endRadius: 520, options: [])
ctx.drawRadialGradient(gradient([rgb(0xFFB3C6, 0.55), rgb(0xFFB3C6, 0)]), startCenter: CGPoint(x: 300, y: 640), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 640), endRadius: 260, options: [])
ctx.restoreGState()

// MARK: Vinyl record (solid, sits behind the glass cover)
let rc = CGPoint(x: 600, y: 560), rr: CGFloat = 215
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.6))
ctx.addEllipse(in: circle(rc, rr)); ctx.setFillColor(rgb(0x121212)); ctx.fillPath()
ctx.restoreGState()
ctx.setLineWidth(2)
for r in stride(from: rr - 18, to: 95, by: -14) {
    ctx.setStrokeColor(white(0.08)); ctx.strokeEllipse(in: circle(rc, r))
}
ctx.saveGState()
ctx.addEllipse(in: circle(rc, rr)); ctx.clip()
ctx.drawLinearGradient(gradient([white(0), white(0.16), white(0)]),
                       start: CGPoint(x: rc.x - 60, y: rc.y + 200), end: CGPoint(x: rc.x + 160, y: rc.y - 120), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: circle(rc, 80)); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFF8FA8), rgb(0xFF4F78)]),
                       start: CGPoint(x: rc.x, y: rc.y + 80), end: CGPoint(x: rc.x, y: rc.y - 80), options: [])
ctx.restoreGState()
ctx.addEllipse(in: circle(rc, 12)); ctx.setFillColor(rgb(0x121212)); ctx.fillPath()

// MARK: Glass album cover
let cover = CGRect(x: 190, y: 330, width: 440, height: 440)
let coverPath = CGPath(roundedRect: cover, cornerWidth: 60, cornerHeight: 60, transform: nil)
glass(coverPath, tint: white(0.04), blur: 18, refraction: 1.1, rim: 6)

// Music note: bright white with a green glow, like light inside the glass
let cfg = NSImage.SymbolConfiguration(pointSize: 250, weight: .semibold)
if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(cfg),
   let noteCG = note.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let w = note.size.width, h = note.size.height
    let r = CGRect(x: cover.midX - w / 2 - 6, y: cover.midY - h / 2, width: w, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xFF4F9A, 0.9))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.clip(to: r, mask: noteCG)
    ctx.drawLinearGradient(gradient([white(1), rgb(0xFFE3F0)]),
                           start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: Green glass tag
let tw: CGFloat = 290, th: CGFloat = 150, tip: CGFloat = 70
var xf = CGAffineTransform(translationX: 690, y: 275).rotated(by: .pi / 7)
let tag = CGMutablePath()
tag.move(to: CGPoint(x: -tw / 2 + tip, y: th / 2))
tag.addLine(to: CGPoint(x: tw / 2 - 30, y: th / 2))
tag.addQuadCurve(to: CGPoint(x: tw / 2, y: th / 2 - 30), control: CGPoint(x: tw / 2, y: th / 2))
tag.addLine(to: CGPoint(x: tw / 2, y: -th / 2 + 30))
tag.addQuadCurve(to: CGPoint(x: tw / 2 - 30, y: -th / 2), control: CGPoint(x: tw / 2, y: -th / 2))
tag.addLine(to: CGPoint(x: -tw / 2 + tip, y: -th / 2))
tag.addLine(to: CGPoint(x: -tw / 2 + 8, y: -8))
tag.addQuadCurve(to: CGPoint(x: -tw / 2 + 8, y: 8), control: CGPoint(x: -tw / 2 - 4, y: 0))
tag.closeSubpath()
tag.addEllipse(in: CGRect(x: -tw / 2 + 48, y: -17, width: 34, height: 34))  // hole (even-odd)
let tagPath = tag.copy(using: &xf)!
glass(tagPath, tint: rgb(0xFFCC33, 0.88), blur: 16, refraction: 1.06, rim: 5, eo: true)
// label lines
ctx.saveGState()
ctx.concatenate(xf)
ctx.setLineCap(.round); ctx.setLineWidth(16); ctx.setStrokeColor(rgb(0x7A3A00, 0.6))
for (i, len) in [150.0, 105.0].enumerated() {
    let y = CGFloat(22 - i * 44)
    ctx.move(to: CGPoint(x: -tw / 2 + 108, y: y)); ctx.addLine(to: CGPoint(x: -tw / 2 + 108 + len, y: y))
}
ctx.strokePath()
ctx.restoreGState()

// MARK: Glass rim on the icon body itself
ctx.saveGState()
ctx.addPath(bodyPath); ctx.setLineWidth(8); ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([white(0.40), white(0.06), white(0.02), white(0.06), white(0.25)], [0, 0.3, 0.5, 0.7, 1]),
                       start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
ctx.restoreGState()

// MARK: Save
let img = ctx.makeImage()!
let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
