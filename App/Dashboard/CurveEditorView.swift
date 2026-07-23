import SwiftUI
import TelemetryShared

/// The draggable fan-curve editor: temperature across, RPM up, the curve in
/// magenta (it commands the fan), the live temperature cursor in cyan (it is
/// data). Nobody ships this free on Apple Silicon; it is the reason Telemetry
/// exists.
struct CurveEditorView: View {
    @Binding var curve: FanCurve
    let minRPM: Double
    let maxRPM: Double
    /// Live input temperature, drawn as a cursor so users see the curve act.
    let liveTempC: Double?
    /// Called when a drag gesture completes — the moment to persist/apply.
    let onCommit: () -> Void

    @State private var selectedIndex: Int?
    @State private var dragging = false

    // Fixed, honest domains: 20–110 °C and 0–max RPM.
    private let tempRange: ClosedRange<Double> = 20...110
    private var rpmRange: ClosedRange<Double> { 0...max(maxRPM, 1) }

    private let pointHitRadius: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space8) {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    canvas(size: size)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(size: size))
                .onTapGesture(count: 2) { location in
                    insertPoint(at: location, size: size)
                }
            }
            .frame(minHeight: 260)

            editorToolbar
        }
    }

    // MARK: - Drawing

    private func canvas(size: CGSize) -> some View {
        Canvas { context, _ in
            drawGrid(context: context, size: size)
            drawHybridZone(context: context, size: size)
            drawMinRPMFloor(context: context, size: size)
            drawCurve(context: context, size: size)
            drawLiveCursor(context: context, size: size)
            drawPoints(context: context, size: size)
        }
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        // Horizontal RPM gridlines: max 4, hairline, quiet.
        let rpmSteps = [2000.0, 4000, 6000]
        for rpm in rpmSteps where rpm < maxRPM {
            let y = yFor(rpm: rpm, size: size)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(Palette.hairline), lineWidth: Metrics.hairline)
            context.draw(
                Text(verbatim: "\(Int(rpm))").font(Typo.axisLabel).foregroundStyle(Palette.textTertiary),
                at: CGPoint(x: 4, y: y - 8), anchor: .leading
            )
        }
        // Temperature ticks every 20 °C.
        for temp in stride(from: 40.0, through: 100, by: 20) {
            let x = xFor(temp: temp, size: size)
            context.draw(
                Text(verbatim: "\(Int(temp))°").font(Typo.axisLabel).foregroundStyle(Palette.textTertiary),
                at: CGPoint(x: x, y: size.height - 8), anchor: .center
            )
        }
    }

    private func drawHybridZone(context: GraphicsContext, size: CGSize) {
        guard let hybrid = curve.hybridAuto else { return }
        let x = xFor(temp: hybrid.releaseBelowC, size: size)
        let zone = Path(CGRect(x: 0, y: 0, width: x, height: size.height))
        context.fill(zone, with: .color(Palette.nominal.opacity(0.07)))
        var edge = Path()
        edge.move(to: CGPoint(x: x, y: 0))
        edge.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(
            edge, with: .color(Palette.nominal.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )
        context.draw(
            Text("AUTO ZONE").font(Typo.sensorLabel).foregroundStyle(Palette.nominal.opacity(0.8)),
            at: CGPoint(x: max(x / 2, 34), y: 14), anchor: .center
        )
    }

    private func drawMinRPMFloor(context: GraphicsContext, size: CGSize) {
        // Forced control cannot go below F0Mn — show the floor honestly
        // instead of letting points imply RPMs the fan cannot hold.
        let y = yFor(rpm: minRPM, size: size)
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(
            line, with: .color(Palette.textTertiary.opacity(0.4)),
            style: StrokeStyle(lineWidth: Metrics.hairline, dash: [2, 3])
        )
    }

    private func drawCurve(context: GraphicsContext, size: CGSize) {
        let pts = curve.points.map { point(in: size, for: $0) }
        guard pts.count > 1 else { return }

        // Extend flat to both edges: exactly how evaluation behaves.
        var path = Path()
        path.move(to: CGPoint(x: 0, y: pts[0].y))
        path.addLine(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.addLine(to: CGPoint(x: size.width, y: pts[pts.count - 1].y))

        // Underfill: accent fading to nothing.
        var fill = path
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [Palette.accentControl.opacity(0.22), .clear]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        context.stroke(path, with: .color(Palette.accentControl), lineWidth: 2)
    }

    private func drawLiveCursor(context: GraphicsContext, size: CGSize) {
        guard let temp = liveTempC, tempRange.contains(temp) else { return }
        let x = xFor(temp: temp, size: size)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(Palette.accentData.opacity(0.6)), lineWidth: 1)

        // Where the curve would put the fan right now.
        let target = CurveMath.targetRPM(curve: curve.points, tempC: temp)
        let dot = CGPoint(x: x, y: yFor(rpm: target, size: size))
        context.fill(
            Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)),
            with: .color(Palette.accentData)
        )
        context.draw(
            Text(verbatim: String(format: "%.0f°", temp))
                .font(Typo.axisLabel).foregroundStyle(Palette.accentData),
            at: CGPoint(x: x, y: size.height - 20), anchor: .center
        )
    }

    private func drawPoints(context: GraphicsContext, size: CGSize) {
        for (index, cp) in curve.points.enumerated() {
            let p = point(in: size, for: cp)
            let isSelected = index == selectedIndex
            let radius: CGFloat = isSelected ? 7 : 5
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(Palette.bgCard)
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(Palette.accentControl), lineWidth: 2
            )
            if isSelected {
                context.draw(
                    Text(verbatim: "\(Int(cp.tempC))° · \(Int(cp.rpm))")
                        .font(Typo.axisLabel).foregroundStyle(Palette.textSecondary),
                    at: CGPoint(x: p.x, y: max(p.y - 18, 10)), anchor: .center
                )
            }
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack(spacing: Metrics.space16) {
            Button("Add point") { insertPointInLargestGap() }
                .buttonStyle(.plain).font(Typo.caption)
                .foregroundStyle(curve.points.count < 8 ? Palette.accentData : Palette.textTertiary)
                .disabled(curve.points.count >= 8)

            Button("Remove point") { removeSelected() }
                .buttonStyle(.plain).font(Typo.caption)
                .foregroundStyle(
                    selectedIndex != nil && curve.points.count > 2
                        ? Palette.accentData : Palette.textTertiary
                )
                .disabled(selectedIndex == nil || curve.points.count <= 2)

            Spacer()
            Text("drag points · double-click to add")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: - Gestures

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragging {
                    selectedIndex = nearestPointIndex(to: value.startLocation, size: size)
                    dragging = selectedIndex != nil
                }
                guard dragging, let index = selectedIndex else { return }
                movePoint(at: index, to: value.location, size: size)
            }
            .onEnded { _ in
                if dragging {
                    dragging = false
                    curve = curve.sanitized(minRPM: minRPM, maxRPM: maxRPM)
                    onCommit()
                }
            }
    }

    private func nearestPointIndex(to location: CGPoint, size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, cp) in curve.points.enumerated() {
            let p = point(in: size, for: cp)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d <= pointHitRadius, d < (best?.distance ?? .infinity) {
                best = (index, d)
            }
        }
        return best?.index
    }

    private func movePoint(at index: Int, to location: CGPoint, size: CGSize) {
        var temp = tempFor(x: location.x, size: size)
        var rpm = rpmFor(y: location.y, size: size)

        // Snap to honest increments; clamp between neighbours so points
        // cannot cross (which would make evaluation order-dependent).
        temp = (temp).rounded()
        rpm = (rpm / 50).rounded() * 50
        let lower = index > 0 ? curve.points[index - 1].tempC + 1 : tempRange.lowerBound
        let upper = index < curve.points.count - 1
            ? curve.points[index + 1].tempC - 1 : tempRange.upperBound
        temp = min(max(temp, lower), upper)
        rpm = min(max(rpm, minRPM), maxRPM)

        curve.points[index] = CurvePoint(tempC: temp, rpm: rpm)
    }

    private func insertPoint(at location: CGPoint, size: CGSize) {
        guard curve.points.count < 8 else { return }
        let temp = tempFor(x: location.x, size: size).rounded()
        let rpm = CurveMath.targetRPM(curve: curve.points, tempC: temp)
        curve.points.append(CurvePoint(tempC: temp, rpm: rpm))
        curve = curve.sanitized(minRPM: minRPM, maxRPM: maxRPM)
        selectedIndex = curve.points.firstIndex { abs($0.tempC - temp) < 1.5 }
        onCommit()
    }

    private func insertPointInLargestGap() {
        guard curve.points.count < 8, curve.points.count >= 2 else { return }
        var bestGap: (index: Int, span: Double) = (0, 0)
        for i in 1..<curve.points.count {
            let span = curve.points[i].tempC - curve.points[i - 1].tempC
            if span > bestGap.span { bestGap = (i, span) }
        }
        let a = curve.points[bestGap.index - 1], b = curve.points[bestGap.index]
        let mid = CurvePoint(tempC: ((a.tempC + b.tempC) / 2).rounded(),
                             rpm: (((a.rpm + b.rpm) / 2) / 50).rounded() * 50)
        curve.points.insert(mid, at: bestGap.index)
        selectedIndex = bestGap.index
        onCommit()
    }

    private func removeSelected() {
        guard let index = selectedIndex, curve.points.count > 2 else { return }
        curve.points.remove(at: index)
        selectedIndex = nil
        onCommit()
    }

    // MARK: - Coordinate mapping

    private func xFor(temp: Double, size: CGSize) -> CGFloat {
        let f = (temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)
        return CGFloat(f) * size.width
    }

    private func yFor(rpm: Double, size: CGSize) -> CGFloat {
        let f = (rpm - rpmRange.lowerBound) / (rpmRange.upperBound - rpmRange.lowerBound)
        return size.height - CGFloat(f) * size.height
    }

    private func tempFor(x: CGFloat, size: CGSize) -> Double {
        tempRange.lowerBound + Double(x / size.width) * (tempRange.upperBound - tempRange.lowerBound)
    }

    private func rpmFor(y: CGFloat, size: CGSize) -> Double {
        rpmRange.lowerBound + Double((size.height - y) / size.height)
            * (rpmRange.upperBound - rpmRange.lowerBound)
    }

    private func point(in size: CGSize, for cp: CurvePoint) -> CGPoint {
        CGPoint(x: xFor(temp: cp.tempC, size: size), y: yFor(rpm: cp.rpm, size: size))
    }
}
