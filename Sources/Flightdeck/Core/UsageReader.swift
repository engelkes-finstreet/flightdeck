import Foundation

/// One rate-limit window as Claude Code reports it.
struct UsageWindow: Equatable {
    /// 0–100. Claude Code's own figure, not a local estimate.
    let percent: Double
    /// When the window rolls over, if the source told us.
    let resetsAt: Date?

    /// The reading predates the window it describes, so the percentage is no
    /// longer about the window that is running now. Usage after a rollover
    /// starts from zero and only grows, but by how much is unknowable from
    /// here — so this is surfaced rather than papered over with a `0%`.
    func hasReset(by now: Date) -> Bool {
        guard let resetsAt else { return false }
        return now >= resetsAt
    }
}

/// Where a reading came from, which is also how much to trust its age.
enum UsageSource: Equatable {
    /// The status-line tap: rewritten by every session on every render, so it
    /// tracks the real numbers within seconds.
    case statusLine
    /// `~/.claude.json`'s `cachedUsageUtilization`, which Claude Code only
    /// refreshes when it actually asks the server (opening `/usage`, nearing a
    /// limit). Correct when written, but can sit unchanged for many hours.
    case cache

    var isLive: Bool { self == .statusLine }
}

struct UsageSnapshot: Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    /// When Claude Code obtained these numbers — not when we read the file.
    var measuredAt: Date
    var source: UsageSource

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil }
}

/// Reads the 5-hour and weekly rate-limit windows from whatever Claude Code
/// has left on disk.
///
/// Two sources, because neither is sufficient alone:
///
/// - `~/.claude/flightdeck-usage.json`, written by the status-line tap in
///   `scripts/flightdeck-usage.sh`. `rate_limits` is a documented status-line
///   field, delivered live to every session on every render, so this is the
///   only genuinely current source — but it exists only once the tap is
///   installed, and only after a session's first API response.
/// - `~/.claude.json`'s `cachedUsageUtilization`, always present but refreshed
///   on demand rather than continuously. Measured on 2.1.250 it sat 20 hours
///   stale through a full day of sessions, so it is a fallback that must be
///   shown with its age, never as a live figure.
///
/// The fresher reading wins, and its age travels with it.
struct UsageReader {
    private let tapURL: URL
    private let configURL: URL
    /// `~/.claude.json` is rewritten constantly and is a few hundred KB, so
    /// re-parsing it on every FSEvent burst would be wasteful. The tap file is
    /// tiny and is read every time.
    private let cacheReadInterval: TimeInterval = 5

    private var cached: UsageSnapshot?
    private var cachedStamp: (modified: Date, size: Int)?
    private var lastCacheRead: Date = .distantPast

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.tapURL = home.appendingPathComponent(".claude/flightdeck-usage.json")
        self.configURL = home.appendingPathComponent(".claude.json")
    }

    /// Best reading available right now, or nil when neither source has one.
    mutating func snapshot(now: Date = Date()) -> UsageSnapshot? {
        let live = readTap()
        let fallback = readCache(now: now)
        switch (live, fallback) {
        case let (live?, fallback?): return live.measuredAt >= fallback.measuredAt ? live : fallback
        case let (live?, nil):       return live
        case let (nil, fallback?):   return fallback
        case (nil, nil):             return nil
        }
    }

    // MARK: - Status-line tap

    private func readTap() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: tapURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any]
        else { return nil }

        // Claude Code drops a window from `rate_limits` once its reset passes,
        // so an absent window means "rolled over", not "unknown".
        func window(_ key: String) -> UsageWindow? {
            guard let entry = limits[key] as? [String: Any],
                  let percent = (entry["used_percentage"] as? NSNumber)?.doubleValue
            else { return nil }
            let resets = (entry["resets_at"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(percent: percent, resetsAt: resets)
        }

        let written = (root["written_at"] as? NSNumber)?.doubleValue
        let snapshot = UsageSnapshot(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            measuredAt: written.map { Date(timeIntervalSince1970: $0) } ?? .distantPast,
            source: .statusLine
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    // MARK: - `~/.claude.json` cache

    private mutating func readCache(now: Date) -> UsageSnapshot? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path)
        let stamp = (
            modified: (attributes?[.modificationDate] as? Date) ?? .distantPast,
            size: (attributes?[.size] as? NSNumber)?.intValue ?? 0
        )
        // Byte-identical file: the last parse still stands.
        if let cachedStamp, cachedStamp == stamp { return cached }
        // Changed, but not long enough ago to be worth re-parsing.
        if now.timeIntervalSince(lastCacheRead) < cacheReadInterval { return cached }

        lastCacheRead = now
        cachedStamp = stamp
        cached = parseCache()
        return cached
    }

    private func parseCache() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: configURL),
              let slice = Self.extractObject(named: "cachedUsageUtilization", from: data),
              let root = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any],
              let utilization = root["utilization"] as? [String: Any]
        else { return nil }

        func window(_ key: String) -> UsageWindow? {
            guard let entry = utilization[key] as? [String: Any],
                  let percent = (entry["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return UsageWindow(percent: percent,
                               resetsAt: Self.date(fromISO: entry["resets_at"] as? String))
        }

        let fetched = (root["fetchedAtMs"] as? NSNumber)?.doubleValue
        let snapshot = UsageSnapshot(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            measuredAt: fetched.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast,
            source: .cache
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    /// Pulls one top-level object out of a large JSON document by scanning for
    /// its key and brace-matching, so the whole of `~/.claude.json` — hundreds
    /// of KB of unrelated project state — never has to be deserialised.
    ///
    /// String-aware, so a `{` inside a value cannot throw off the depth count.
    static func extractObject(named key: String, from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let needle = "\"\(key)\"".data(using: .utf8).map({ [UInt8]($0) }),
              let keyEnd = index(after: needle, in: bytes)
        else { return nil }

        // Step past the colon to the opening brace. Anything else on the way —
        // `null`, a string, an array — means there is no object to extract.
        var index = keyEnd
        while index < bytes.count, bytes[index] != UInt8(ascii: "{") {
            switch bytes[index] {
            case UInt8(ascii: ":"), UInt8(ascii: " "),
                 UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                index += 1
            default:
                return nil
            }
        }
        guard index < bytes.count else { return nil }

        let start = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if inString {
                if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"):  depth += 1
                case UInt8(ascii: "}"):
                    depth -= 1
                    if depth == 0 { return data.subdata(in: start..<(index + 1)) }
                default: break
                }
            }
            index += 1
        }
        return nil
    }

    /// Index of the first byte after `needle`, or nil when it does not occur.
    private static func index(after needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        var start = 0
        while start <= limit {
            if haystack[start] == needle[0] {
                var offset = 1
                while offset < needle.count, haystack[start + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return start + needle.count }
            }
            start += 1
        }
        return nil
    }

    /// `2026-08-27T19:00:00.605766+00:00` — more fractional digits than
    /// `ISO8601DateFormatter` reliably accepts, so the fraction is trimmed to
    /// milliseconds and a plain internet-date parse is kept as a fallback.
    static func date(fromISO text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = text[text.index(after: dot)..<end]
            if fraction.count > 3 {
                let trimmed = fraction.prefix(3)
                text.replaceSubrange(text.index(after: dot)..<end, with: trimmed)
            }
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
