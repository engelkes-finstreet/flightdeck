import Foundation

/// Last-resort title generation for sessions whose intent cannot be recovered
/// from disk.
///
/// Deliberately a fallback, not the default path. `TranscriptReader` already
/// resolves most sessions for free and instantly — user prose, or the heading
/// of a file the prompt referenced. This kicks in only for the residue:
/// sessions with no recoverable intent, and rambling multi-sentence prompts
/// that do not read as a title.
///
/// One `claude -p` call per session, ever. Results are cached to disk, so a
/// title is generated once and then costs nothing for the life of the session.
/// Measured cost is ~7-8s wall clock, which is why it runs detached and the
/// card shows its deterministic title until the summary lands.
@MainActor
final class TitleService: ObservableObject {
    /// A generated title, tied to the seed it came from.
    struct Entry: Codable {
        let title: String
        /// Hash of the seed this was generated from. If the seed changes — a
        /// real prompt lands where there was none — the old title is discarded
        /// rather than shown forever.
        let seedHash: String
    }

    /// sessionId -> generated title.
    @Published private(set) var entries: [String: Entry] = [:]

    private var inFlight: Set<String> = []
    /// Seeds we tried and could not summarise; don't retry in a loop. Keyed by
    /// session *and* seed, so a new prompt gets a fresh attempt.
    private var failed: Set<String> = []
    private let maxConcurrent = 2
    private let cacheURL: URL
    private let enabled: Bool

    init(enabled: Bool = true) {
        self.enabled = enabled
        let support = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Flightdeck")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.cacheURL = support.appendingPathComponent("titles.json")
        loadCache()
    }

    /// The generated title for this session, but only if it came from the
    /// seed we are currently looking at.
    func summary(for sessionId: String, seed: String) -> String? {
        guard let entry = entries[sessionId],
              entry.seedHash == Self.hash(Self.normalize(seed))
        else { return nil }
        return entry.title
    }

    /// True while at least one title is being generated.
    var isGenerating: Bool { !inFlight.isEmpty }

    /// Ask for a title if one is warranted and not already known or running.
    func requestIfNeeded(sessionId: String, seed: String) {
        let normalized = Self.normalize(seed)
        let seedHash = Self.hash(normalized)
        let attemptKey = "\(sessionId):\(seedHash)"
        guard enabled,
              !normalized.isEmpty,
              summary(for: sessionId, seed: seed) == nil,
              !inFlight.contains(sessionId),
              !failed.contains(attemptKey),
              inFlight.count < maxConcurrent
        else { return }

        guard let executable = Self.claudeExecutable() else {
            // Without the CLI there is nothing to fall back to; stop asking.
            failed.insert(attemptKey)
            return
        }

        inFlight.insert(sessionId)
        Task.detached(priority: .utility) {
            let result = await Self.generate(executable: executable, seed: normalized)
            await MainActor.run {
                self.inFlight.remove(sessionId)
                if let result {
                    self.entries[sessionId] = Entry(title: result, seedHash: seedHash)
                    self.persist()
                } else {
                    self.failed.insert(attemptKey)
                }
            }
        }
    }

    /// Exactly the text that gets sent, so the hash describes the real input.
    static func normalize(_ seed: String) -> String {
        String(seed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))
    }

    /// FNV-1a. Only needs to be stable and collision-resistant enough to tell
    /// one prompt from another.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return String(value, radix: 16)
    }

    // MARK: - Generation

    private static func generate(executable: URL, seed: String) async -> String? {
        let instruction = """
        Below is the opening request of a coding session. Reply with ONLY a \
        title for it: at most 8 words, sentence case, no quotes, no trailing \
        period, naming the work being done.

        Describe the task itself. Never describe the session — "new session", \
        "session cleared" and the like are always wrong answers. If the request \
        is a slash command, title it by what the command was asked to do.

        ---
        \(seed)
        """

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-p",
            "--model", "claude-haiku-4-5-20251001",
            // Nothing about naming a task needs this machine's MCP servers.
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        ]
        // A GUI app inherits a bare environment; give the CLI a sane HOME/PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = (environment["PATH"] ?? "") + ":" + executable.deletingLastPathComponent().path
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch { return nil }

        stdin.fileHandleForWriting.write(Data(instruction.utf8))
        try? stdin.fileHandleForWriting.close()

        // Don't let a wedged CLI leak a process for the app's lifetime.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if process.isRunning { process.terminate() }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return sanitize(String(data: data, encoding: .utf8))
    }

    /// The model is asked for a bare title, but never trust that: reject
    /// anything that looks like prose, an error, or a refusal.
    static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A single line only.
        if let newline = text.firstIndex(of: "\n") { text = String(text[..<newline]) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.“” "))
        guard !text.isEmpty, text.count <= 90 else { return nil }
        guard text.split(separator: " ").count <= 12 else { return nil }
        let lowered = text.lowercased()
        for marker in ["error", "i cannot", "i can't", "i'm unable", "sorry"] {
            if lowered.hasPrefix(marker) { return nil }
        }
        return text
    }

    /// A GUI process gets `/usr/bin:/bin:/usr/sbin:/sbin`, which does not
    /// include where Claude Code installs itself.
    static func claudeExecutable() -> URL? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        // Entries from before seed-hashing carry no provenance and cannot be
        // validated, so they are dropped rather than trusted.
        guard let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            try? FileManager.default.removeItem(at: cacheURL)
            return
        }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
