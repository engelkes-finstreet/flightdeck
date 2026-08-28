import Foundation

/// Recovers what a session is *about* from its transcript, without ever
/// calling a model.
///
/// Claude Code stores transcripts as JSONL at
/// `~/.claude/projects/<slugified-cwd>/<sessionId>.jsonl`. The opening lines
/// are frequently machinery rather than intent: slash commands and skill
/// invocations write `isMeta` entries wrapped in `<local-command-caveat>` /
/// `<command-name>` tags. Taking line one naively is what makes other
/// dashboards title a card "Base directory for this skill: /Users/...".
struct TranscriptReader {
    private let projectsRoot: URL
    /// sessionId -> resolved intent. A session's opening turn never changes,
    /// so one successful read is final.
    private var cache: [String: Intent] = [:]

    /// Everything we could learn deterministically, in preference order.
    struct Intent {
        /// The user's own words.
        var prose: String?
        /// A slash command as typed, e.g. `/skills:implement @issues/08.md`.
        var command: String?
        /// First markdown heading of a file the prompt referenced with `@`.
        /// Usually the best title available: written by a human, descriptive,
        /// and free.
        var referenceHeading: String?
        var gitBranch: String?

        /// Whether a transcript exists on disk at all.
        var transcriptFound = false
        /// When we last tried to read this session, to throttle retries.
        var attemptedAt = Date.distantPast

        /// Best deterministic title, or nil if we found nothing usable.
        var best: String? { referenceHeading ?? prose ?? command }

        /// What to hand the model when a title must be generated.
        ///
        /// Only ever recovered intent — never transcript machinery. Seeding
        /// from the raw opening lines made the model summarise
        /// `<local-command-caveat>` and `/clear` into titles like
        /// "Session cleared, ready for a new task".
        var generationSeed: String? { prose ?? command }

        /// Whether a generated title would be an improvement: nothing was
        /// recovered, or all we have is a bare slash command, or the prose is
        /// a rambling paragraph rather than something you can scan.
        var wantsGeneratedTitle: Bool {
            // A human-written heading already beats anything generated.
            if referenceHeading != nil { return false }
            // Short prose reads fine as a title; long prose does not.
            if let prose { return prose.count > 120 }
            // A bare slash command is worth summarising.
            if command != nil { return true }
            // Nothing recovered means nothing to summarise. Generating here is
            // how boilerplate turned into a title.
            return false
        }
    }

    init(projectsRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects")) {
        self.projectsRoot = projectsRoot
    }

    /// Claude Code's directory naming: path separators and dots both become `-`.
    /// `/Users/me/.t3/worktrees/x` -> `-Users-me--t3-worktrees-x`
    static func slug(for cwd: String) -> String {
        var out = ""
        for character in cwd {
            out.append(character == "/" || character == "." ? "-" : character)
        }
        return out
    }

    mutating func resolve(sessionId: String, cwd: String) -> Intent {
        if let hit = cache[sessionId] {
            // A recovered title is final — a session's opening turn never changes.
            if hit.best != nil { return hit }
            // Otherwise the transcript may not exist yet, or may still be
            // growing toward its first real turn. Retry, but not on every
            // FSEvents tick.
            if Date().timeIntervalSince(hit.attemptedAt) < 5 { return hit }
        }
        var intent = read(sessionId: sessionId, cwd: cwd)
        intent.attemptedAt = Date()
        cache[sessionId] = intent
        return intent
    }

    private func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let direct = projectsRoot
            .appendingPathComponent(Self.slug(for: cwd))
            .appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        // Resumed sessions and worktree moves can leave the transcript under a
        // different project slug than the current cwd, so fall back to a scan.
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil
        ) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func read(sessionId: String, cwd: String) -> Intent {
        guard let url = transcriptURL(sessionId: sessionId, cwd: cwd),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return Intent() }
        defer { try? handle.close() }

        var intent = Intent()
        intent.transcriptFound = true

        // The opening turns are what we want; read a bounded prefix rather
        // than the whole transcript, which runs to megabytes.
        let prefix = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
        for line in prefix.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }

            if intent.gitBranch == nil,
               let value = object["gitBranch"] as? String,
               Self.isUsefulBranch(value) {
                intent.gitBranch = value
            }
            guard object["type"] as? String == "user",
                  (object["isSidechain"] as? Bool) != true,
                  object["toolUseResult"] == nil,
                  let message = object["message"] as? [String: Any],
                  let raw = Self.rawText(from: message["content"])
            else { continue }

            if intent.prose == nil,
               (object["isMeta"] as? Bool) != true,
               let prose = Self.prose(from: raw) {
                intent.prose = prose
                intent.referenceHeading = intent.referenceHeading
                    ?? Self.heading(forReferencesIn: prose, cwd: cwd)
                // Real prose is the strongest signal; stop here.
                break
            }
            if intent.command == nil, let command = Self.command(from: raw) {
                intent.command = command
                intent.referenceHeading = intent.referenceHeading
                    ?? Self.heading(forReferencesIn: command, cwd: cwd)
            }
        }
        return intent
    }

    /// A detached HEAD or an empty value tells you nothing; don't take up room.
    private static func isUsefulBranch(_ value: String) -> Bool {
        !value.isEmpty && value != "HEAD"
    }

    /// Flattens message `content` (a string, or an array of typed blocks).
    private static func rawText(from content: Any?) -> String? {
        let text: String
        switch content {
        case let string as String:
            text = string
        case let blocks as [[String: Any]]:
            text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
        default:
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The user's own words, or nil if this is machinery
    /// (`<local-command-caveat>`, `<command-name>`, `<system-reminder>`, ...).
    private static func prose(from text: String) -> String? {
        text.hasPrefix("<") ? nil : text
    }

    /// Slash-command invocations rendered the way the user typed them:
    /// `/mattpocock-skills:implement @issues/07-kit-lock.md Everything else...`
    private static func command(from text: String) -> String? {
        guard let name = tag("command-name", in: text), name.hasPrefix("/") else { return nil }
        // Session hygiene commands are not what the session is *about*.
        let ignored: Set<String> = ["/clear", "/compact", "/resume", "/exit", "/cost", "/status"]
        guard !ignored.contains(name) else { return nil }
        if let args = tag("command-args", in: text), !args.isEmpty {
            return "\(name) \(args)"
        }
        return name
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - `@file` references

    /// When a prompt points at a file — `@.scratch/issues/08-golem-init.md` —
    /// that file's own first heading describes the work far better than the
    /// command that opened it, and costs nothing to read.
    static func heading(forReferencesIn text: String, cwd: String) -> String? {
        for path in references(in: text) {
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: cwd).appendingPathComponent(path)
            guard let heading = firstHeading(of: url) else { continue }
            return heading
        }
        return nil
    }

    private static func references(in text: String) -> [String] {
        var out: [String] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            guard token.hasPrefix("@"), token.count > 1 else { continue }
            var path = String(token.dropFirst())
            // Trailing prose punctuation is not part of the path.
            while let last = path.last, ",.;:)]\"'".contains(last) { path.removeLast() }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }

    private static func firstHeading(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8 * 1024),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        for line in text.split(separator: "\n").prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed
                .drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespaces)
                // Backticks are markdown, not information.
                .replacingOccurrences(of: "`", with: "")
            guard !heading.isEmpty else { continue }
            return heading
        }
        return nil
    }
}
