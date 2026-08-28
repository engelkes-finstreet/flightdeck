import Foundation

/// Compact "how long ago" stamps in the style of the agent roster: `0s`,
/// `47s`, `3m`, `2h`, `4d`. Deliberately terse — these sit in a narrow column
/// and update every second.
enum RelativeTime {
    static func short(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:     return "\(Int(seconds))s"
        case ..<3600:   return "\(Int(seconds / 60))m"
        case ..<86400:  return "\(Int(seconds / 3600))h"
        default:        return "\(Int(seconds / 86400))d"
        }
    }

    static func ago(since date: Date, now: Date = Date()) -> String {
        "\(short(since: date, now: now)) ago"
    }
}
