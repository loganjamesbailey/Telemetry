// Generates docs/social-preview.png (1280x640) — the card GitHub serves to
// Facebook/Twitter/iMessage when the repo link is shared.
//
// Layout rules, in order of authority:
//   1. GitHub's repo-card template: every important detail stays inside a
//      40pt (~80px) safe border so platform crops never cut content.
//   2. Golden ratio inside that frame: the dial's center sits on the golden
//      section of the width, type steps down by φ (56/34/21/16), arc width
//      and needle counterweight are R/φ³.
//   3. Liquid-glass finish: specular highlight along the lit arc (glossy
//      tube), glass panel behind the wordmark with a lit top edge, soft
//      sheen across the card. Core linework stays crisp — glow never
//      touches ticks or numerals.
//
// Run: swift Scripts/generate-social-preview.swift
// Upload at: repo Settings → General → Social preview (GitHub has no API).

import AppKit

let W = 1280, H = 640
let SAFE: CGFloat = 84  // GitHub template crop margin, with a little slack
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

// ── Background: surface gradient + one soft diagonal sheen (glass, not fog) ─
let bg = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0x1B / 255, green: 0x1B / 255, blue: 0x26 / 255, alpha: 1),
        bg0,
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(H)), end: .zero, options: [])

let sheen = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(gray: 1, alpha: 0.030), CGColor(gray: 1, alpha: 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    sheen, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: 640, y: 240), options: []
)

// ── Dial geometry ────────────────────────────────────────────────────────────
// Golden section of the width; radius chosen so the numeral ring's topmost
// point stays inside the safe border: centerY + numeralR ≤ H - SAFE.
let goldenX = CGFloat(W) - CGFloat(W) / phi        // ≈ 489
let dialR: CGFloat = 168
let arcWidth = dialR / phi / phi / phi             // ≈ 40
let tickInner = dialR + 24
let numeralR = tickInner + 24 + 22                 // ≈ 238
// Vertical: centre the gauge's visual band (top numeral to bottom numerals)
// in the canvas — top extent lands ~118px from the top edge, comfortably
// inside the template's crop band on both sides.
let center = CGPoint(x: goldenX, y: 274)
let startAngle = deg(215), endAngle = deg(-35), valueAngle = deg(40)

// Face disc: the instrument's physical face.
let face = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0x23 / 255, green: 0x23 / 255, blue: 0x30 / 255, alpha: 0.9),
        CGColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x1C / 255, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    face, startCenter: center, startRadius: 0,
    endCenter: center, endRadius: dialR * 1.32, options: []
)

// Glass lens reflection: a soft crescent on the upper-left of the face.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - dialR * 0.92, y: center.y - dialR * 0.92,
                          width: dialR * 1.84, height: dialR * 1.84))
ctx.clip()
let lens = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(gray: 1, alpha: 0.055), CGColor(gray: 1, alpha: 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    lens,
    start: CGPoint(x: center.x - dialR, y: center.y + dialR),
    end: CGPoint(x: center.x + dialR * 0.2, y: center.y - dialR * 0.2),
    options: []
)
ctx.restoreGState()

// Inner ring at R/φ.
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
ctx.setLineWidth(1.5)
ctx.strokeEllipse(in: CGRect(
    x: center.x - dialR / phi, y: center.y - dialR / phi,
    width: dialR / phi * 2, height: dialR / phi * 2
))

// Track: the unlit remainder of the scale, with a faint glass top-edge.
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
ctx.setLineWidth(arcWidth)
ctx.addArc(center: center, radius: dialR, startAngle: startAngle, endAngle: endAngle, clockwise: true)
ctx.strokePath()
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.05))
ctx.setLineWidth(arcWidth * 0.20)
ctx.addArc(center: center, radius: dialR + arcWidth * 0.24,
           startAngle: startAngle, endAngle: endAngle, clockwise: true)
ctx.strokePath()

// Value arc: tight glow (bloom must not swallow the linework), crisp core.
for (blur, alpha) in [(30.0, 0.28), (12.0, 0.45), (0.0, 1.0)] {
    ctx.saveGState()
    if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: cyan.copy(alpha: alpha)) }
    ctx.setStrokeColor(blur > 0 ? cyan.copy(alpha: alpha)! : cyan)
    ctx.setLineWidth(arcWidth)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: dialR, startAngle: startAngle, endAngle: valueAngle, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()
}
// Liquid-glass specular: a bright highlight running along the tube's outer edge.
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
ctx.setLineWidth(arcWidth * 0.16)
ctx.setLineCap(.round)
ctx.addArc(center: center, radius: dialR + arcWidth * 0.26,
           startAngle: startAngle, endAngle: valueAngle, clockwise: true)
ctx.strokePath()

// Ticks, above everything glowy: crisp hierarchy.
let tickCount = 25
for i in 0..<tickCount {
    let t = CGFloat(i) / CGFloat(tickCount - 1)
    let a = startAngle + (endAngle - startAngle) * t
    let major = i % 6 == 0
    let outer = tickInner + (major ? 24 : 12)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: major ? 0.60 : 0.24))
    ctx.setLineWidth(major ? 4 : 2.5)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: center.x + cos(a) * tickInner, y: center.y + sin(a) * tickInner))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
    ctx.strokePath()
}

// ── Text helpers ─────────────────────────────────────────────────────────────
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)

func withText(_ body: () -> Void) {
    NSGraphicsContext.current = nsCtx
    body()
    NSGraphicsContext.current = nil
}

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

// Scale numerals at the major ticks.
withText {
    let numeralFont = NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
    for (i, label) in [(0, "40"), (6, "55"), (12, "70"), (18, "85"), (24, "100")] {
        let t = CGFloat(i) / CGFloat(tickCount - 1)
        let a = startAngle + (endAngle - startAngle) * t
        drawCentered(
            label,
            at: CGPoint(x: center.x + cos(a) * numeralR, y: center.y + sin(a) * numeralR),
            font: numeralFont, color: NSColor(white: 1, alpha: 0.46)
        )
    }
}

// ── Needle ───────────────────────────────────────────────────────────────────
let tip = CGPoint(x: center.x + cos(valueAngle) * (dialR - arcWidth / 2 - 6),
                  y: center.y + sin(valueAngle) * (dialR - arcWidth / 2 - 6))
let counter = CGPoint(x: center.x - cos(valueAngle) * dialR / phi / phi / phi,
                      y: center.y - sin(valueAngle) * dialR / phi / phi / phi)
for (blur, alpha) in [(18.0, 0.40), (0.0, 1.0)] {
    ctx.saveGState()
    if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: magenta.copy(alpha: alpha)) }
    ctx.setStrokeColor(blur > 0 ? magenta.copy(alpha: alpha)! : magenta)
    ctx.setLineCap(.round)
    ctx.setLineWidth(8)
    ctx.move(to: center)
    ctx.addLine(to: tip)
    ctx.strokePath()
    ctx.setLineWidth(12)
    ctx.move(to: center)
    ctx.addLine(to: counter)
    ctx.strokePath()
    ctx.restoreGState()
}
let hubR: CGFloat = 15
ctx.setFillColor(bg0)
ctx.fillEllipse(in: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))
ctx.setStrokeColor(magenta)
ctx.setLineWidth(4.5)
ctx.strokeEllipse(in: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))
ctx.setFillColor(CGColor(gray: 1, alpha: 0.5))
ctx.fillEllipse(in: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))

// ── Wordmark block on a glass panel ──────────────────────────────────────────
let textX = center.x + numeralR + 44                       // clear of the numeral ring
let panel = CGRect(x: textX - 32, y: 186, width: CGFloat(W) - SAFE - (textX - 32), height: 252)
let panelPath = CGPath(roundedRect: panel, cornerWidth: 22, cornerHeight: 22, transform: nil)

// Glass fill + inner top light.
ctx.saveGState()
ctx.addPath(panelPath)
ctx.clip()
ctx.setFillColor(CGColor(gray: 1, alpha: 0.040))
ctx.fill(panel)
let panelLight = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(gray: 1, alpha: 0.05), CGColor(gray: 1, alpha: 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    panelLight,
    start: CGPoint(x: 0, y: panel.maxY),
    end: CGPoint(x: 0, y: panel.maxY - panel.height * 0.5),
    options: []
)
ctx.restoreGState()

// Hairline border + lit top edge (the liquid-glass signature).
ctx.addPath(panelPath)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
ctx.setLineWidth(1.5)
ctx.strokePath()
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.30))
ctx.setLineWidth(1.5)
ctx.move(to: CGPoint(x: panel.minX + 22, y: panel.maxY))
ctx.addLine(to: CGPoint(x: panel.maxX - 22, y: panel.maxY))
ctx.strokePath()

withText {
    // Type scale by φ: 56 → 34 → 21 → 16.
    drawText("TELEMETRY", at: CGPoint(x: textX, y: 344),
             font: .systemFont(ofSize: 56, weight: .semibold),
             color: NSColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255, alpha: 1), kern: 5)
    drawText("Free, open-source fan control", at: CGPoint(x: textX, y: 288),
             font: .systemFont(ofSize: 32, weight: .regular), color: NSColor(white: 1, alpha: 0.64))
    drawText("for Apple Silicon Macs", at: CGPoint(x: textX, y: 246),
             font: .systemFont(ofSize: 32, weight: .regular), color: NSColor(white: 1, alpha: 0.64))
    drawText("CUSTOM CURVES · 0 RPM IDLE · FAIL-SAFE", at: CGPoint(x: textX, y: 200),
             font: .systemFont(ofSize: 15, weight: .medium),
             color: NSColor(white: 1, alpha: 0.42), kern: 1.5)
}

let outPath = "docs/social-preview.png"
guard let image = ctx.makeImage() else { fatalError("image") }
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil
)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
