// Renders the v3 MP3 Tagger icon: clear vinyl on black with a tag to a 1024×1024 PNG.
// Usage: swiftc make_icon_v3.swift -o make_icon_v3 && ./make_icon_v3 out.png
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

// MARK: Black background
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.5))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x050506)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x19191C), rgb(0x0A0A0B), rgb(0x020202)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// MARK: Clear vinyl record
let c = CGPoint(x: 512, y: 540), R: CGFloat = 318
let disc = CGPath(ellipseIn: circle(c, R), transform: nil)
ctx.saveGState()
ctx.addPath(disc); ctx.clip()
// barely-there tint so it reads as clear plastic, with a soft violet/pink shimmer
ctx.drawRadialGradient(gradient([white(0.02), white(0.025), white(0.08)], [0, 0.7, 1]),
                       startCenter: c, startRadius: 0, endCenter: c, endRadius: R, options: [])
ctx.drawLinearGradient(gradient([rgb(0xFF6A88, 0.07), rgb(0xB23AEE, 0.03), rgb(0x4B1FB8, 0.07)]),
                       start: CGPoint(x: c.x - R, y: c.y + R), end: CGPoint(x: c.x + R, y: c.y - R), options: [])
// grooves
ctx.setLineWidth(1.6)
var r = R - 22
var k = 0
while r > 112 {
    ctx.setStrokeColor(white(k % 3 == 0 ? 0.16 : 0.075))
    ctx.strokeEllipse(in: circle(c, r))
    r -= 9; k += 1
}
// two wide light reflections across the grooves (like light on a real record)
for (a0, a1, alpha) in [(CGFloat.pi * 0.62, CGFloat.pi * 0.86, 0.42), (CGFloat.pi * 1.62, CGFloat.pi * 1.86, 0.28)] {
    let wedge = CGMutablePath()
    wedge.move(to: c)
    wedge.addArc(center: c, radius: R, startAngle: a0, endAngle: a1, clockwise: false)
    wedge.closeSubpath()
    ctx.saveGState()
    ctx.addPath(wedge); ctx.clip()
    ctx.drawRadialGradient(gradient([white(0), white(alpha), white(alpha * 0.4)], [0, 0.55, 1]),
                           startCenter: c, startRadius: 100, endCenter: c, endRadius: R, options: [])
    ctx.restoreGState()
}
ctx.restoreGState()
// outer edge: bright glassy rim
ctx.saveGState()
ctx.addPath(disc); ctx.setLineWidth(5); ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([white(0.9), white(0.25), white(0.1), white(0.3), white(0.7)], [0, 0.3, 0.5, 0.7, 1]),
                       start: CGPoint(x: c.x - R, y: c.y + R), end: CGPoint(x: c.x + R, y: c.y - R), options: [])
ctx.restoreGState()
// clear center label area with a thin ring
ctx.setStrokeColor(white(0.35)); ctx.setLineWidth(2.5)
ctx.strokeEllipse(in: circle(c, 104))
ctx.setStrokeColor(white(0.18)); ctx.setLineWidth(1.5)
ctx.strokeEllipse(in: circle(c, 60))
// spindle hole (black shows through)
ctx.addEllipse(in: circle(c, 17)); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
ctx.setStrokeColor(white(0.5)); ctx.setLineWidth(2)
ctx.strokeEllipse(in: circle(c, 17))

// MARK: Tag, tied to the spindle hole
let tagCenter = CGPoint(x: 700, y: 262)
let angle = -CGFloat.pi / 5
let tw: CGFloat = 300, th: CGFloat = 156, tip: CGFloat = 72
var xf = CGAffineTransform(translationX: tagCenter.x, y: tagCenter.y).rotated(by: angle)
// where the tag's hole ends up
let holeLocal = CGPoint(x: -tw / 2 + 64, y: 0)
let hole = holeLocal.applying(xf)
// string: from the spindle hole, draping down to the tag's hole
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: rgb(0x000000, 0.6))
ctx.setStrokeColor(rgb(0xF2E6C9)); ctx.setLineWidth(5); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: c.x + 6, y: c.y - 6))
ctx.addCurve(to: hole, control1: CGPoint(x: c.x + 40, y: c.y - 170), control2: CGPoint(x: hole.x - 110, y: hole.y + 40))
ctx.strokePath()
ctx.restoreGState()

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
tag.addEllipse(in: CGRect(x: holeLocal.x - 17, y: -17, width: 34, height: 34))  // hole (even-odd)
let tagPath = tag.copy(using: &xf)!
glass(tagPath, tint: rgb(0xFFC83D, 0.9), blur: 14, refraction: 1.05, rim: 5, eo: true)
// string loop over the tag's hole edge
ctx.saveGState()
ctx.setStrokeColor(rgb(0xF2E6C9)); ctx.setLineWidth(5); ctx.setLineCap(.round)
let loopA = CGPoint(x: holeLocal.x - 20, y: 6).applying(xf), loopB = CGPoint(x: holeLocal.x + 4, y: 19).applying(xf)
ctx.move(to: hole); ctx.addQuadCurve(to: loopB, control: loopA); ctx.strokePath()
ctx.restoreGState()
// label lines on the tag
ctx.saveGState()
ctx.concatenate(xf)
ctx.setLineCap(.round); ctx.setLineWidth(17); ctx.setStrokeColor(rgb(0x7A3A00, 0.6))
for (i, len) in [150.0, 100.0].enumerated() {
    let y = CGFloat(24 - i * 46)
    ctx.move(to: CGPoint(x: -tw / 2 + 112, y: y)); ctx.addLine(to: CGPoint(x: -tw / 2 + 112 + len, y: y))
}
ctx.strokePath()
ctx.restoreGState()

// MARK: Glass rim on the icon body itself
ctx.saveGState()
ctx.addPath(bodyPath); ctx.setLineWidth(8); ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([white(0.35), white(0.06), white(0.02), white(0.06), white(0.2)], [0, 0.3, 0.5, 0.7, 1]),
                       start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
ctx.restoreGState()

// MARK: Save
let img = ctx.makeImage()!
let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
