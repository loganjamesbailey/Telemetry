import Foundation
import Observation
import TelemetryShared

/// Bounded time-series history for the charts. Two tiers:
/// - hot: 1 sample/s, 1 h (3600 points/series)
/// - long: 1 sample/30 s, 24 h (2880 points/series)
/// The long tier is fed by decimating the hot stream as it arrives, so total
/// memory stays a few hundred KB no matter how long the app runs.
@MainActor
@Observable
final class HistoryStore {
    struct Sample: Sendable, Identifiable {
        let time: Date
        let value: Double
        var id: Date { time }
    }

    enum Series: CaseIterable {
        case primaryTemp
        case fanRPM
    }

    enum Range: String, CaseIterable {
        case tenMinutes = "10 MIN"
        case hour = "1 HR"
        case day = "24 HR"

        var seconds: TimeInterval {
            switch self {
            case .tenMinutes: return 600
            case .hour: return 3600
            case .day: return 86400
            }
        }
    }

    private var hot: [Series: [Sample]] = [:]
    private var long: [Series: [Sample]] = [:]
    private var pendingLongWindow: [Series: [Sample]] = [:]

    private let hotCapacity = 3600
    private let longCapacity = 2880
    private let longStride: TimeInterval = 30

    func append(primaryTemp: Double?, fanRPM: Double?, at time: Date = Date()) {
        if let primaryTemp { append(.primaryTemp, Sample(time: time, value: primaryTemp)) }
        if let fanRPM { append(.fanRPM, Sample(time: time, value: fanRPM)) }
    }

    private func append(_ series: Series, _ sample: Sample) {
        hot[series, default: []].append(sample)
        if hot[series]!.count > hotCapacity {
            hot[series]!.removeFirst(hot[series]!.count - hotCapacity)
        }

        // Long tier: collect a 30 s window, then commit its max. Max (not
        // mean) because for thermal data the peak is the honest summary —
        // averaging hides the spikes that made the fan act.
        pendingLongWindow[series, default: []].append(sample)
        let window = pendingLongWindow[series]!
        if let first = window.first, sample.time.timeIntervalSince(first.time) >= longStride {
            if let peak = window.max(by: { $0.value < $1.value }) {
                long[series, default: []].append(peak)
                if long[series]!.count > longCapacity {
                    long[series]!.removeFirst(long[series]!.count - longCapacity)
                }
            }
            pendingLongWindow[series] = []
        }
    }

    /// Samples for a range, downsampled to ~`maxPoints` via min/max pairs per
    /// bucket so peaks and troughs survive (plain striding would erase them).
    func samples(_ series: Series, range: Range, maxPoints: Int = 500) -> [Sample] {
        let source = range == .day ? long[series, default: []] : hot[series, default: []]
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let visible = source.drop { $0.time < cutoff }
        guard visible.count > maxPoints else { return Array(visible) }

        let bucketSize = Int((Double(visible.count) / Double(maxPoints / 2)).rounded(.up))
        var out: [Sample] = []
        out.reserveCapacity(maxPoints)
        var bucket: [Sample] = []
        for sample in visible {
            bucket.append(sample)
            if bucket.count >= bucketSize {
                appendMinMax(of: bucket, to: &out)
                bucket = []
            }
        }
        appendMinMax(of: bucket, to: &out)
        return out
    }

    private func appendMinMax(of bucket: [Sample], to out: inout [Sample]) {
        guard !bucket.isEmpty else { return }
        guard bucket.count > 1 else {
            out.append(bucket[0])
            return
        }
        let lo = bucket.min { $0.value < $1.value }!
        let hi = bucket.max { $0.value < $1.value }!
        // Chronological order within the pair keeps the line honest.
        out.append(contentsOf: lo.time <= hi.time ? [lo, hi] : [hi, lo])
    }
}
