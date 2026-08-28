import SwiftUI

/// The right-hand status indicator: a spinning ring while the agent works, a
/// filled check once it hands back, a bell for anything awaiting you.
struct StatusGlyph: View {
    let activity: Activity
    var size: CGFloat = 17

    var body: some View {
        ZStack {
            switch activity {
            case .busy, .compacting, .other:
                ring
            case .idle:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.done)
            case .needsInput:
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(Theme.attention)
            }
        }
        .font(.system(size: size))
        .frame(width: size + 3, height: size + 3)
        .help(activity.label)
    }

    /// Rotation is derived from the clock rather than from a `repeatForever`
    /// animation on @State. An implicit animation is cancelled whenever an
    /// ancestor re-renders with a transaction of its own — which the roster
    /// does every couple of seconds — leaving the ring frozen mid-turn and the
    /// app claiming nothing is happening. A `TimelineView` cannot get stuck:
    /// each frame recomputes the angle from the current time, so the ring
    /// turns for exactly as long as the agent is working, and pauses only when
    /// the window is not being drawn at all.
    private var ring: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval)) { context in
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Theme.working, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: size * 0.85, height: size * 0.85)
                .rotationEffect(.degrees(Self.angle(at: context.date)))
                // The angle is already the truth for this instant; never let an
                // inherited animation interpolate towards it.
                .transaction { $0.animation = nil }
        }
    }

    /// One full turn, in seconds.
    private static let period: TimeInterval = 1.1
    /// 30fps is smooth for a shape this small and keeps the draw cost trivial
    /// even with a screenful of working agents.
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    /// Phase against a shared reference point, so every spinner in the window
    /// turns in lockstep instead of each starting wherever it appeared.
    private static func angle(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return phase * 360
    }
}
