// Renders the MP3 Tagger app icon to a 1024×1024 PNG.
// Usage: swiftc make_icon.swift -o make_icon && ./make_icon out.png
import AppKit

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
}
func shadow(blur: CGFloat, y: CGFloat, alpha: CGFloat) {
    ctx.setShadow(offset: CGSize(width: 0, height: y), blur: blur, color: rgb(0x000000, alpha))
}

// MARK: Background squircle (Apple icon grid: 824pt body, ~185pt corners)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
shadow(blur: 28, y: -12, alpha: 0.35)
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x2A1060)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFF6A88), rgb(0xB23AEE), rgb(0x4B1FB8)]),
                       start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
// soft top highlight
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)]),
                       startCenter: CGPoint(x: 330, y: 880), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: 880), endRadius: 520, options: [])
ctx.restoreGState()

// MARK: Vinyl record peeking out behind the cover
let rc = CGPoint(x: 600, y: 560), rr: CGFloat = 215
ctx.saveGState()
shadow(blur: 30, y: -14, alpha: 0.4)
ctx.addEllipse(in: CGRect(x: rc.x - rr, y: rc.y - rr, width: rr * 2, height: rr * 2))
ctx.setFillColor(rgb(0x141018)); ctx.fillPath()
ctx.restoreGState()
ctx.setLineWidth(2)
for r in stride(from: rr - 18, to: 95, by: -14) {
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.07))
    ctx.strokeEllipse(in: CGRect(x: rc.x - r, y: rc.y - r, width: r * 2, height: r * 2))
}
// sheen
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: rc.x - rr, y: rc.y - rr, width: rr * 2, height: rr * 2)); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)]),
                       start: CGPoint(x: rc.x - 60, y: rc.y + 200), end: CGPoint(x: rc.x + 160, y: rc.y - 120), options: [])
ctx.restoreGState()
let lr: CGFloat = 78
ctx.addEllipse(in: CGRect(x: rc.x - lr, y: rc.y - lr, width: lr * 2, height: lr * 2))
ctx.setFillColor(rgb(0xFF6A88)); ctx.fillPath()
ctx.addEllipse(in: CGRect(x: rc.x - 12, y: rc.y - 12, width: 24, height: 24))
ctx.setFillColor(rgb(0x141018)); ctx.fillPath()

// MARK: Album cover
let cover = CGRect(x: 205, y: 345, width: 420, height: 420)
let coverPath = CGPath(roundedRect: cover, cornerWidth: 44, cornerHeight: 44, transform: nil)
ctx.saveGState()
shadow(blur: 40, y: -18, alpha: 0.45)
ctx.addPath(coverPath); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(coverPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xF1E9FF)]),
                       start: CGPoint(x: cover.midX, y: cover.maxY), end: CGPoint(x: cover.midX, y: cover.minY), options: [])
ctx.restoreGState()

// Music note (SF Symbol), filled with the brand gradient
let cfg = NSImage.SymbolConfiguration(pointSize: 250, weight: .semibold)
if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(cfg),
   let noteCG = note.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let w = note.size.width, h = note.size.height
    let r = CGRect(x: cover.midX - w / 2 - 6, y: cover.midY - h / 2, width: w, height: h)
    ctx.saveGState()
    ctx.clip(to: r, mask: noteCG)
    ctx.drawLinearGradient(gradient([rgb(0xFF6A88), rgb(0x8A2BE2)]),
                           start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
    ctx.restoreGState()
}

// MARK: Label tag (the "tagger")
ctx.saveGState()
ctx.translateBy(x: 690, y: 285)
ctx.rotate(by: .pi / 7)
let tw: CGFloat = 290, th: CGFloat = 150, tip: CGFloat = 70
let tag = CGMutablePath()
tag.move(to: CGPoint(x: -tw / 2 + tip, y: th / 2))
tag.addLine(to: CGPoint(x: tw / 2 - 26, y: th / 2))
tag.addQuadCurve(to: CGPoint(x: tw / 2, y: th / 2 - 26), control: CGPoint(x: tw / 2, y: th / 2))
tag.addLine(to: CGPoint(x: tw / 2, y: -th / 2 + 26))
tag.addQuadCurve(to: CGPoint(x: tw / 2 - 26, y: -th / 2), control: CGPoint(x: tw / 2, y: -th / 2))
tag.addLine(to: CGPoint(x: -tw / 2 + tip, y: -th / 2))
tag.addLine(to: CGPoint(x: -tw / 2 + 8, y: -8))
tag.addQuadCurve(to: CGPoint(x: -tw / 2 + 8, y: 8), control: CGPoint(x: -tw / 2 - 4, y: 0))
tag.closeSubpath()
// cut the string hole out
let hole = CGRect(x: -tw / 2 + 48, y: -17, width: 34, height: 34)
ctx.saveGState()
shadow(blur: 26, y: -12, alpha: 0.4)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(tag)
ctx.setFillColor(rgb(0xFFC83D)); ctx.fillPath()
ctx.addPath(tag); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFD95A), rgb(0xFFA928)]),
                       start: CGPoint(x: 0, y: th / 2), end: CGPoint(x: 0, y: -th / 2), options: [])
ctx.resetClip()
ctx.setBlendMode(.clear)
ctx.fillEllipse(in: hole)
ctx.endTransparencyLayer()
ctx.restoreGState()
// "ID3" lines on the tag
ctx.setLineCap(.round)
ctx.setLineWidth(16)
ctx.setStrokeColor(rgb(0x7A3A00, 0.55))
for (i, len) in [150.0, 105.0].enumerated() {
    let y = CGFloat(22 - i * 44)
    ctx.move(to: CGPoint(x: -tw / 2 + 108, y: y)); ctx.addLine(to: CGPoint(x: -tw / 2 + 108 + len, y: y))
}
ctx.strokePath()
ctx.restoreGState()

// MARK: Save
let img = ctx.makeImage()!
let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
