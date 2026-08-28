import SwiftUI

/// The two rate-limit windows, sitting above the footer.
///
/// One row per window rather than two side by side: at the default 440pt this
/// is the only way the bar stays long enough to read as a bar, and the app is
/// meant to be legible from across a desk.
struct UsageStrip: View {
    let snapshot: UsageSnapshot
    @Environment(\.textScale) private var textScale

    var body: some View {
        // The reset countdowns and the staleness note both move in real time.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                meter("5h", snapshot.fiveHour, now: context.date)
                meter("week", snapshot.sevenDay, now: context.date)
                // A cached reading can be many hours old, and a dimmed bar is
                // too quiet a way to say so. Age is stated, not implied.
                if !snapshot.source.isLive {
                    Text("cached · measured \(RelativeTime.ago(since: snapshot.measuredAt, now: context.date))")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .font(.system(size: Theme.Size.footer.scaled(textScale)))
            .monospacedDigit()
            .padding(.horizontal, 15)
            .padding(.top, 9)
            .padding(.bottom, 3)
            .help(explanation(now: context.date))
        }
    }

    /// Label, bar and percentage form one block on the left; the countdown is
    /// pushed to the window's right edge, so the two rows' reset times line up
    /// as their own column instead of trailing the bars at ragged offsets.
    @ViewBuilder
    private func meter(_ label: String, _ window: UsageWindow?, now: Date) -> some View {
        let live = window.map { !$0.hasReset(by: now) } ?? false
        // A window Claude Code has dropped, or one whose reset has passed,
        // says nothing about the window running now.
        let tint = live ? Self.tint(forPercent: window!.percent) : Theme.dormant

        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: CGFloat(34).scaled(textScale), alignment: .leading)

            bar(fraction: live ? window!.percent / 100 : 0, tint: tint)

            Text(live ? "\(Int(window!.percent.rounded()))%" : "—")
                .font(.system(size: Theme.Size.usage.scaled(textScale), weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: CGFloat(40).scaled(textScale), alignment: .trailing)

            // Keeps a gap between the bar block and the countdown once the
            // window is wide enough to have one to give.
            Spacer(minLength: 14)

            Text(live ? (window?.resetsAt.map { "resets in \(Self.until($0, now: now))" } ?? "")
                      : "window reset")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .opacity(snapshot.source.isLive ? 1 : 0.72)
    }

    private func bar(fraction: Double, tint: Color) -> some View {
        let height = CGFloat(10).scaled(textScale)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
        // Flexible, but claimed ahead of the trailing spacer, so the bar takes
        // the width first and only the leftover widens the gap.
        .frame(minWidth: CGFloat(70).scaled(textScale),
               maxWidth: CGFloat(220).scaled(textScale))
        .layoutPriority(1)
    }

    /// Explains where the numbers came from, because a cached reading can be
    /// hours old and that changes what it is worth.
    private func explanation(now: Date) -> String {
        let age = RelativeTime.ago(since: snapshot.measuredAt, now: now)
        switch snapshot.source {
        case .statusLine:
            return "Claude Code's own 5-hour and weekly rate-limit figures,"
                + " read live from the status line \(age)."
        case .cache:
            return "Claude Code's own rate-limit figures, as of \(age) — it last"
                + " refreshed them then. For live numbers, wrap your status line"
                + " in scripts/flightdeck-usage.sh (see the README)."
        }
    }

    /// Green while there is room, amber once the window is more than half
    /// gone, red when running out matters.
    static func tint(forPercent percent: Double) -> Color {
        switch percent {
        case ..<50:  return Theme.done
        case ..<85:  return Theme.attention
        default:     return Theme.critical
        }
    }

    /// `2h 14m`, `1d 11h` — how long the window has left.
    static func until(_ date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let days = hours / 24
        let rest = hours % 24
        return rest == 0 ? "\(days)d" : "\(days)d \(rest)h"
    }
}
