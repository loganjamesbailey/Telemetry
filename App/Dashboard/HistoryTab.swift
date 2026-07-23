import Charts
import SwiftUI

/// Temperature and fan-speed history. Two separate charts with fixed, honest
/// axes — a dual-axis chart invites misreading, and the two quantities keep
/// their app-wide hues (temp cyan, RPM magenta).
struct HistoryTab: View {
    @Environment(SensorStore.self) private var store

    @State private var range: HistoryStore.Range = .tenMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space16) {
            rangePicker

            chartCard(
                title: store.primaryReading?.name ?? "Temperature",
                unit: store.unit.symbol,
                series: .primaryTemp,
                color: Palette.accentData,
                domain: store.unit.convert(20)...store.unit.convert(110),
                transform: { store.unit.convert($0) }
            )
            chartCard(
                title: "Fan speed",
                unit: "RPM",
                series: .fanRPM,
                color: Palette.accentControl,
                domain: 0...(store.fan.map { $0.maxRPM + 200 } ?? 7400)
            )
        }
    }

    private var rangePicker: some View {
        HStack(spacing: Metrics.space8) {
            ForEach(HistoryStore.Range.allCases, id: \.self) { candidate in
                Button {
                    range = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(Typo.sensorLabel)
                        .tracking(0.6)
                        .foregroundStyle(range == candidate ? Palette.textPrimary : Palette.textTertiary)
                        .padding(.horizontal, Metrics.space8)
                        .padding(.vertical, Metrics.space4)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.radiusControl)
                                .fill(range == candidate ? Palette.bgOverlay : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func chartCard(
        title: String, unit: String, series: HistoryStore.Series,
        color: Color, domain: ClosedRange<Double>,
        transform: (Double) -> Double = { $0 }
    ) -> some View {
        let samples = store.history.samples(series, range: range).map {
            HistoryStore.Sample(time: $0.time, value: transform($0.value))
        }
        return Card {
            VStack(alignment: .leading, spacing: Metrics.space8) {
                HStack {
                    FieldLabel(text: title)
                    Spacer()
                    if let last = samples.last {
                        Text(verbatim: "\(Int(last.value)) \(unit)")
                            .font(Typo.readoutSmall)
                            .foregroundStyle(color)
                    }
                }

                if samples.count > 1 {
                    chart(samples: samples, color: color, domain: domain)
                        .frame(height: 160)
                        .drawingGroup()
                } else {
                    Text("Collecting…")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .frame(height: 160, alignment: .center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func chart(
        samples: [HistoryStore.Sample], color: Color, domain: ClosedRange<Double>
    ) -> some View {
        Chart {
            AreaPlot(
                samples, x: .value("Time", \.time), y: .value("Value", \.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [color.opacity(0.22), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
            // .monotone: no overshoot — a temperature line must never appear
            // to cross a threshold the data never reached.
            .interpolationMethod(.monotone)

            LinePlot(
                samples, x: .value("Time", \.time), y: .value("Value", \.value)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel()
                    .font(Typo.axisLabel)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel()
                    .font(Typo.axisLabel)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }
}
