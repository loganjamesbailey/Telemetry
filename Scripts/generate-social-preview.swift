// Generates docs/social-preview.png (1280x640) — the card GitHub serves to
// Facebook/Twitter/iMessage when the repo link is shared.
//
// Composition follows the golden ratio: the dial's center sits on the golden
// section of the canvas width, the text block owns the larger golden segment,
// and the type scale steps down by φ (56 → 34 → 21 → 16). The gauge is drawn
// as a real instrument: face disc, inner ring at R/φ, numbered scale, tick
// hierarchy rendered crisp above the glow, counterweighted needle.
//
// Run: swift Scripts/generate-social-preview.swift
// Upload at: repo Settings → General → Social preview (GitHub has no API for it).

import AppKit

let W = 1280, H = 640
let phi: CGFloat = 1.6180339887

guard let ctx = CGContext(
    data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("context") }

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

let cyan = CGColor(red: 0x36 / 255, green: 0xF9 / 255, blue: 0xF6 / 255, alpha: 1)
let magenta = CGColor(red: 0xFF / 255, green: 0x7E / 255, blue: 0xDB / 255, alpha: 1)
let bg0 = CGColor(red: 0x0D / 255, green: 0x0D / 255, blue: 0x12 / 255, alpha: 1)

// Background: the app's surface gradient, full bleed.
let bg = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0x1B / 255, green: 0x1B / 255, blue: 0x26 / 255, alpha: 1),
        bg0,
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(H)), end: .zero, options: [])

// ── Dial ─────────────────────────────────────────────────────────────────────
// Focal point on the golden section: the width divides 489 : 791 (1 : φ).
let goldenX = CGFloat(W) - CGFloat(W) / phi  // ≈ 489
let center = CGPoint(x: goldenX, y: 316)
let dialR: CGFloat = 186
let arcWidth = dialR / phi / phi / phi  // ≈ 44 → φ³ below the radius
let startAngle = deg(215), endAngle = deg(-35), valueAngle = deg(40)

// Face disc: a barely-lighter instrument face so the gauge reads as an object.
let face = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0x23 / 255, green: 0x23 / 255, blue: 0x30 / 255, alpha: 0.85),
        CGColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x1C / 255, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.saveGState()
ctx.drawRadialGradient(
    face, startCenter: center, startRadius: 0,
    endCenter: center, endRadius: dialR * 1.38, options: []
)
ctx.restoreGState()

// Inner ring at R/φ: quiet structural detail on the face.
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.07))
ctx.setLineWidth(1.5)
ctx.strokeEllipse(in: CGRect(
    x: center.x - dialR / phi, y: center.y - dialR / phi,
    width: dialR / phi * 2, height: dialR / phi * 2
))

// Track: the unlit remainder of the scale.
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.09))
ctx.setLineWidth(arcWidth)
ctx.addArc(center: center, radius: dialR, startAngle: startAngle, endAngle: endAngle, clockwise: true)
ctx.strokePath()

// Value arc: cyan with layered glow.
for (blur, alpha) in [(46.0, 0.30), (20.0, 0.50), (0.0, 1.0)] {
    ctx.saveGState()
    if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: cyan.copy(alpha: alpha)) }
    ctx.setStrokeColor(blur > 0 ? cyan.copy(alpha: alpha)! : cyan)
    ctx.setLineWidth(arcWidth)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: dialR, startAngle: startAngle, endAngle: valueAngle, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()
}

// Tick hierarchy, drawn ABOVE the glow so the scale stays crisp: 25 ticks,
// majors every 6th, brighter and longer.
let tickCount = 25
let tickInner = dialR + 26
for i in 0..<tickCount {
    let t = CGFloat(i) / CGFloat(tickCount - 1)
    let a = startAngle + (endAngle - startAngle) * t
    let major = i % 6 == 0
    let outer = tickInner + (major ? 26 : 13)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: major ? 0.55 : 0.22))
    ctx.setLineWidth(major ? 4 : 2.5)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: center.x + cos(a) * tickInner, y: center.y + sin(a) * tickInner))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
    ctx.strokePath()
}

// ── Text (drawn via AppKit) ──────────────────────────────────────────────────
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = nsCtx

func drawText(_ string: String, at point: CGPoint, font: NSFont, color: NSColor, kern: CGFloat = 0) {
    NSAttributedString(
        string: string,
        attributes: [.font: font, .foregroundColor: color, .kern: kern]
    ).draw(at: point)
}

func drawCentered(_ string: String, at point: CGPoint, font: NSFont, color: NSColor) {
    let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    let size = attr.size()
    attr.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
}

// Scale numerals at the major ticks: 40–100 °, the gauge's honest range.
let numeralFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
for (i, label) in [(0, "40"), (6, "55"), (12, "70"), (18, "85"), (24, "100")] {
    let t = CGFloat(i) / CGFloat(tickCount - 1)
    let a = startAngle + (endAngle - startAngle) * t
    let r = tickInner + 26 + 24
    drawCentered(
        label,
        at: CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r),
        font: numeralFont, color: NSColor(white: 1, alpha: 0.38)
    )
}

NSGraphicsContext.current = nil

// ── Needle (over the numerals' layer, under nothing) ────────────────────────
let tip = CGPoint(x: center.x + cos(valueAngle) * (dialR - arcWidth / 2 - 6),
                  y: center.y + sin(valueAngle) * (dialR - arcWidth / 2 - 6))
// Counterweight: the tail opposite the tip — long enough to read as a
// machined part rather than an artifact (R/φ³ ≈ 44 px).
let counter = CGPoint(x: center.x - cos(valueAngle) * dialR / phi / phi / phi,
                      y: center.y - sin(valueAngle) * dialR / phi / phi / phi)
for (blur, alpha) in [(24.0, 0.45), (0.0, 1.0)] {
    ctx.saveGState()
    if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: magenta.copy(alpha: alpha)) }
    ctx.setStrokeColor(blur > 0 ? magenta.copy(alpha: alpha)! : magenta)
    ctx.setLineCap(.round)
    ctx.setLineWidth(9)
    ctx.move(to: center)
    ctx.addLine(to: tip)
    ctx.strokePath()
    ctx.setLineWidth(13)
    ctx.move(to: center)
    ctx.addLine(to: counter)
    ctx.strokePath()
    ctx.restoreGState()
}
let hubR: CGFloat = 17
ctx.setFillColor(bg0)
ctx.fillEllipse(in: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))
ctx.setStrokeColor(magenta)
ctx.setLineWidth(5)
ctx.strokeEllipse(in: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))
// Hub jewel: tiny center dot, like a bearing.
ctx.setFillColor(CGColor(gray: 1, alpha: 0.5))
ctx.fillEllipse(in: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))

// ── Wordmark block: the larger golden segment ────────────────────────────────
NSGraphicsContext.current = nsCtx
let textX = goldenX + dialR + 26 + 26 + 48  // clear of the tick+numeral ring
// Type scale by φ: 56 → 34 → 21 → 16.
drawText("TELEMETRY", at: CGPoint(x: textX, y: 372),
         font: .systemFont(ofSize: 56, weight: .semibold),
         color: NSColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255, alpha: 1), kern: 5)
drawText("Free, open-source fan control", at: CGPoint(x: textX, y: 306),
         font: .systemFont(ofSize: 34, weight: .regular), color: NSColor(white: 1, alpha: 0.62))
drawText("for Apple Silicon Macs", at: CGPoint(x: textX, y: 260),
         font: .systemFont(ofSize: 34, weight: .regular), color: NSColor(white: 1, alpha: 0.62))
drawText("CUSTOM CURVES · 0 RPM IDLE · FAIL-SAFE", at: CGPoint(x: textX, y: 196),
         font: .systemFont(ofSize: 16, weight: .medium),
         color: NSColor(white: 1, alpha: 0.40), kern: 1.6)
NSGraphicsContext.current = nil

let outPath = "docs/social-preview.png"
guard let image = ctx.makeImage() else { fatalError("image") }
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil
)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
