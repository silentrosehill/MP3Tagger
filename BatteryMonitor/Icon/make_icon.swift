// Renders the Battery Monitor icon (headphones over a green battery, on black) to a 1024×1024 PNG.
// Usage: swiftc make_icon.swift -o make_icon && ./make_icon out.png
import AppKit
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)! }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// Background: black rounded square with a soft shadow
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.5))
ctx.addPath(rounded(body, 185)); ctx.setFillColor(rgb(0x050506)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(body, 185)); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x1C1C20), rgb(0x0A0A0B), rgb(0x020202)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Headphones (SF Symbol, filled white)
if let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 400, weight: .semibold)) {
    let size = symbol.size
    let scale = min(400 / size.width, 360 / size.height)
    let w = size.width * scale, h = size.height * scale
    let r = CGRect(x: 512 - w / 2, y: 470, width: w, height: h)
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    symbol.draw(in: r)
    ctx.setBlendMode(.sourceIn)
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xC9C9CF)]),
                           start: CGPoint(x: 512, y: r.maxY), end: CGPoint(x: 512, y: r.minY), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// Battery: outline, nub, green fill at ~75%
let battery = CGRect(x: 262, y: 220, width: 470, height: 190)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.9)); ctx.setLineWidth(22)
ctx.addPath(rounded(battery, 52)); ctx.strokePath()
ctx.setFillColor(rgb(0xFFFFFF, 0.9))
ctx.addPath(rounded(CGRect(x: battery.maxX + 18, y: battery.midY - 42, width: 34, height: 84), 14)); ctx.fillPath()
let fill = battery.insetBy(dx: 30, dy: 30)
let level = CGRect(x: fill.minX, y: fill.minY, width: fill.width * 0.75, height: fill.height)
ctx.saveGState()
ctx.addPath(rounded(level, 26)); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x5BF08A), rgb(0x1ED760), rgb(0x0F9A45)]),
                       start: CGPoint(x: 0, y: level.maxY), end: CGPoint(x: 0, y: level.minY), options: [])
ctx.restoreGState()

// Save
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(out.path)")
