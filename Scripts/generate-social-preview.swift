// Generates docs/social-preview.png (1280x640) — the card GitHub serves to
// Facebook/Twitter/iMessage when the repo link is shared. Same house style as
// the app icon: violet-black, Braun dial, cyan/magenta accents.
//
// Run: swift Scripts/generate-social-preview.swift
// Upload at: repo Settings → General → Social preview (GitHub has no API for it).

import AppKit

let W = 1280, H = 640
let s = CGFloat(640)  // dial drawing scale (fits left half)

guard let ctx = CGContext(
    data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("context") }

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

let cyan = CGColor(red: 0x36 / 255, green: 0xF9 / 255, blue: 0xF6 / 255, alpha: 1)
let magenta = CGColor(red: 0xFF / 255, green: 0x7E / 255, blue: 0xDB / 255, alpha: 1)

// Background: the app's surface gradient, full bleed.
let bg = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0x1B / 255, green: 0x1B / 255, blue: 0x26 / 255, alpha: 1),
        CGColor(red: 0x0D / 255, green: 0x0D / 255, blue: 0x12 / 255, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(H)), end: .zero, options: [])

// Dial (same geometry as the icon, no squircle — it sits on the card itself).
let center = CGPoint(x: 300, y: CGFloat(H) / 2)
let dialR = s * 0.30
let startAngle = deg(215), endAngle = deg(-35), valueAngle = deg(40)

let tickCount = 25
for i in 0..<tickCount {
    let t = CGFloat(i) / CGFloat(tickCount - 1)
    let a = startAngle + (endAngle - startAngle) * t
    let major = i % 6 == 0
    let inner = dialR + s * 0.055
    let outer = inner + (major ? s * 0.035 : s * 0.02)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: major ? 0.28 : 0.14))
    ctx.setLineWidth(s * 0.006)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
    ctx.strokePath()
}

let arcWidth = s * 0.055
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
ctx.setLineWidth(arcWidth)
ctx.addArc(center: center, radius: dialR, startAngle: startAngle, endAngle: endAngle, clockwise: true)
ctx.strokePath()

for (blur, alpha) in [(s * 0.10, 0.35), (s * 0.045, 0.55), (0, 1.0)] {
    ctx.saveGState()
    if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: cyan.copy(alpha: alpha)) }
    ctx.setStrokeColor(blur > 0 ? cyan.copy(alpha: alpha)! : cyan)
    ctx.setLineWidth(arcWidth)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: dialR, startAngle: startAngle, endAngle: valueAngle, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()
}

let tip = CGPoint(x: center.x + cos(valueAngle) * (dialR - s * 0.075),
                  y: center.y + sin(valueAngle) * (dialR - s * 0.075))
let tail = CGPoint(x: center.x - cos(valueAngle) * s * 0.03,
                   y: center.y - sin(valueAngle) * s * 0.03)
for (blur, alpha) in [(s * 0.05, 0.5), (0, 1.0)] {
    ctx.saveGState()
    if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: magenta.copy(alpha: alpha)) }
    ctx.setStrokeColor(blur > 0 ? magenta.copy(alpha: alpha)! : magenta)
    ctx.setLineWidth(s * 0.028)
    ctx.setLineCap(.round)
    ctx.move(to: tail)
    ctx.addLine(to: tip)
    ctx.strokePath()
    ctx.restoreGState()
}
let hubR = s * 0.045
ctx.setFillColor(CGColor(red: 0x0D / 255, green: 0x0D / 255, blue: 0x12 / 255, alpha: 1))
ctx.fillEllipse(in: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))
ctx.setStrokeColor(magenta)
ctx.setLineWidth(s * 0.012)
ctx.strokeEllipse(in: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))

// Text block, right side.
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = nsCtx

func drawText(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight,
              color: NSColor, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: kern,
    ]
    NSAttributedString(string: string, attributes: attrs).draw(at: point)
}

let textX: CGFloat = 590
drawText("TELEMETRY", at: CGPoint(x: textX, y: 380), size: 72, weight: .semibold,
         color: NSColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255, alpha: 1), kern: 6)
drawText("Free, open-source fan control", at: CGPoint(x: textX, y: 310), size: 30, weight: .regular,
         color: NSColor(white: 1, alpha: 0.60))
drawText("for Apple Silicon Macs", at: CGPoint(x: textX, y: 268), size: 30, weight: .regular,
         color: NSColor(white: 1, alpha: 0.60))
drawText("CUSTOM CURVES · 0 RPM IDLE · FAIL-SAFE BY DESIGN", at: CGPoint(x: textX, y: 200),
         size: 17, weight: .medium, color: NSColor(white: 1, alpha: 0.38), kern: 1.2)

NSGraphicsContext.current = nil

let outPath = "docs/social-preview.png"
guard let image = ctx.makeImage() else { fatalError("image") }
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil
)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
