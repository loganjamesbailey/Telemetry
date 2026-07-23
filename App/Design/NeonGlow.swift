import SwiftUI

/// The one place glow is allowed to happen.
///
/// Glow means "this is alive, or just changed". Permitted on: the hero
/// readouts, the active chart series, and momentary state-change pulses.
/// Never on chrome, titles, labels, borders, or buttons at rest.
///
/// In light mode glow is forced OFF rather than dimmed — there is no darkness
/// to emit into, so it reads as a printing smudge. That is also the honest
/// design argument (Rams #6), which is why it is enforced here rather than left
/// to each call site's judgement.
struct NeonGlow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let color: Color
    /// 0 = off, 0.6 = steady live value, 1.0 = pulse peak.
    let intensity: Double

    func body(content: Content) -> some View {
        let i = colorScheme == .light ? 0 : intensity
        content
            .shadow(color: color.opacity(0.80 * i), radius: 2)
            .shadow(color: color.opacity(0.50 * i), radius: 6)
            .shadow(color: color.opacity(0.25 * i), radius: 14)
    }
}

extension View {
    /// Tight core + mid halo + wide falloff reads as emission without bloom.
    func neonGlow(_ color: Color, intensity: Double = 0.6) -> some View {
        modifier(NeonGlow(color: color, intensity: intensity))
    }
}

/// Glow intensities, named so call sites state intent rather than a magic number.
enum GlowLevel {
    /// A live value that is simply ticking along.
    static let steady = 0.6
    /// Peak of a state-change pulse.
    static let pulse = 1.0
    static let off = 0.0
}
