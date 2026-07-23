// Generates the app icon: a Braun-style instrument dial in the Telemetry
// design language — near-black violet squircle, hairline tick ring, glowing
// cyan temperature arc, magenta needle. Temp is always cyan and fan always
// magenta everywhere in the app; the icon obeys the same rule.
//
// Run: swift Scripts/generate-icon.swift <output-dir>
// Emits every size the AppIcon.appiconset needs.

import AppKit

let sizes: [(name: String, px: Int)] = [
    ("icon_16", 16), ("icon_32", 32), ("icon_64", 64),
    ("icon_128", 128), ("icon_256", 256), ("icon_512", 512), ("icon_1024", 1024),
]

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

func draw(px: Int, into ctx: CGContext) {
    let s = CGFloat(px)
    let center = CGPoint(x: s / 2, y: s / 2)

    // Canvas is transparent; the squircle is the icon shape (macOS masks and
    // shadows it further on Tahoe, which is fine — ours nests inside).
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Background: violet-black vertical gradient (bg0 → bg2 from the tokens).
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0x1B / 255, green: 0x1B / 255, blue: 0x26 / 255, alpha: 1),
            CGColor(red: 0x0D / 255, green: 0x0D / 255, blue: 0x12 / 255, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // Hairline border keeps the shape legible against dark wallpapers.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(max(s * 0.004, 0.5))
    ctx.strokePath()
    ctx.restoreGState()

    // Dial geometry: a classic gauge sweep, lower-left → top → lower-right.
    let startAngle = deg(215)
    let endAngle = deg(-35)
    let dialR = s * 0.30
    let cyan = CGColor(red: 0x36 / 255, green: 0xF9 / 255, blue: 0xF6 / 255, alpha: 1)
    let magenta = CGColor(red: 0xFF / 255, green: 0x7E / 255, blue: 0xDB / 255, alpha: 1)

    // Tick ring: quiet, structural. Skipped below 64 px — noise at that size.
    if px >= 64 {
        let tickCount = 25
        for i in 0..<tickCount {
            let t = CGFloat(i) / CGFloat(tickCount - 1)
            let a = startAngle + (endAngle - startAngle) * t
            let major = i % 6 == 0
            let inner = dialR + s * 0.055
            let outer = inner + (major ? s * 0.035 : s * 0.02)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: major ? 0.28 : 0.14))
            ctx.setLineWidth(max(s * 0.006, 0.5))
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
            ctx.strokePath()
        }
    }

    // Track: the unlit remainder of the scale (honest: shows the full range).
    let arcWidth = max(s * 0.055, 1.5)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
    ctx.setLineWidth(arcWidth)
    ctx.addArc(center: center, radius: dialR, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.strokePath()

    // Value arc: cyan with layered glow (the triple-shadow recipe, in ink).
    let valueAngle = deg(40)  // ~70% of scale: alive, not alarmed
    for (blur, alpha) in [(s * 0.10, 0.35), (s * 0.045, 0.55), (0, 1.0)] {
        ctx.saveGState()
        if blur > 0 {
            ctx.setShadow(offset: .zero, blur: blur, color: cyan.copy(alpha: alpha))
        }
        ctx.setStrokeColor(blur > 0 ? cyan.copy(alpha: alpha)! : cyan)
        ctx.setLineWidth(arcWidth)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: dialR, startAngle: startAngle, endAngle: valueAngle, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Needle: magenta, pointing at the arc's live end. Fan follows heat —
    // the two accents meet where the action is.
    if px >= 32 {
        let needleAngle = valueAngle
        let tip = CGPoint(
            x: center.x + cos(needleAngle) * (dialR - s * 0.075),
            y: center.y + sin(needleAngle) * (dialR - s * 0.075)
        )
        // Tail stays shorter than the hub radius so nothing pokes out behind it.
        let tail = CGPoint(
            x: center.x - cos(needleAngle) * s * 0.03,
            y: center.y - sin(needleAngle) * s * 0.03
        )
        for (blur, alpha) in [(s * 0.05, 0.5), (0, 1.0)] {
            ctx.saveGState()
            if blur > 0 {
                ctx.setShadow(offset: .zero, blur: blur, color: magenta.copy(alpha: alpha))
            }
            ctx.setStrokeColor(blur > 0 ? magenta.copy(alpha: alpha)! : magenta)
            ctx.setLineWidth(max(s * 0.028, 1))
            ctx.setLineCap(.round)
            ctx.move(to: tail)
            ctx.addLine(to: tip)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Hub: dark disc with a magenta ring — a machined part, not a dot.
        let hubR = max(s * 0.045, 1.5)
        ctx.setFillColor(CGColor(red: 0x0D / 255, green: 0x0D / 255, blue: 0x12 / 255, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))
        ctx.setStrokeColor(magenta)
        ctx.setLineWidth(max(s * 0.012, 0.75))
        ctx.strokeEllipse(in: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))
    }
}

func writePNG(px: Int, name: String, dir: String) {
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("context \(px)") }
    draw(px: px, into: ctx)
    guard let image = ctx.makeImage() else { fatalError("image \(px)") }
    let url = URL(fileURLWithPath: "\(dir)/\(name).png") as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
        fatalError("dest \(px)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for spec in sizes {
    writePNG(px: spec.px, name: spec.name, dir: outDir)
    print("wrote \(spec.name).png (\(spec.px)px)")
}
