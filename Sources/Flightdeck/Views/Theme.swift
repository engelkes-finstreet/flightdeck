import SwiftUI

/// One place for the palette and type scale so light and dark stay coherent
/// and sizes stay consistent across the window.
enum Theme {
    static let canvas = Color(nsColor: .controlBackgroundColor)
    static let card = Color(nsColor: .textBackgroundColor)
    static let hairline = Color.primary.opacity(0.13)

    static let working = Color(red: 0.36, green: 0.40, blue: 0.93)
    static let done = Color(red: 0.13, green: 0.60, blue: 0.38)
    static let attention = Color(red: 0.86, green: 0.52, blue: 0.09)
    static let critical = Color(red: 0.80, green: 0.25, blue: 0.22)
    static let dormant = Color.secondary.opacity(0.55)

    static func accent(for lane: Lane) -> Color {
        switch lane {
        case .needsAttention: return attention
        case .running:        return working
        case .finished:       return done
        case .inactive:       return dormant
        }
    }

    /// Stable per-project tint so you learn a project by its colour.
    /// Brightness is held down a little so it stays legible on a light canvas.
    static func tint(forProject name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash << 5) &+ hash &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }

    /// Base point sizes, before the user's text-scale multiplier.
    enum Size {
        static let projectHeader: CGFloat = 14
        static let headline: CGFloat = 14
        static let meta: CGFloat = 11.5
        static let timestamp: CGFloat = 11.5
        static let count: CGFloat = 11
        static let footer: CGFloat = 11
        /// The rate-limit percentages, the one number in the footer worth reading
        /// from a distance.
        static let usage: CGFloat = 13
        static let glyph: CGFloat = 17
    }
}

/// User-adjustable text scale (⌘+ / ⌘- / ⌘0), threaded through the view tree
/// so every size responds together.
private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension CGFloat {
    /// Point size scaled by the user's preference.
    func scaled(_ factor: CGFloat) -> CGFloat { (self * factor).rounded() }
}
