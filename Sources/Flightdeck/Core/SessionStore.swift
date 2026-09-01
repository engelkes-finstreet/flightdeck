import Foundation
import Combine
import Darwin

/// The single source of truth behind the Flightdeck window.
///
/// Reads `~/.claude/sessions/<pid>.json`, which each Claude Code process
/// rewrites on every state change. Measured on 2.1.250, a `busy -> idle`
/// transition lands on disk within ~70ms, including for detached `--bg`
/// agents and for interactive sessions whose terminal is not frontmost — so
/// an FSEvents subscription gives genuinely live status with no hooks, no
/// polling of the `claude` CLI, and no dependency on window activation.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var lastRefresh: Date = .distantPast
    /// The 5-hour and weekly rate-limit windows, when Claude Code has left a
    /// reading on disk. Nil until one exists.
    @Published private(set) var usage: UsageSnapshot?

    /// Emitted when an agent stops working and hands control back to you.
    var onHandback: ((Session) -> Void)?

    private let sessionsDir: URL
    let titles: TitleService
    let dismissals: DismissalStore
    private var reader = TranscriptReader()
    private var usageReader = UsageReader()
    private var watcher: DirectoryWatcher?
    private var safetyTimer: Timer?
    private var coalesce: DispatchWorkItem?
    /// Previous activity per session, for edge detection.
    private var previousActivity: [String: Activity] = [:]
    /// Dead sessions older than this are dropped rather than listed.
    private let inactiveHorizon: TimeInterval = 60 * 60 * 12

    init(sessionsDir: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/sessions"),
         titles: TitleService? = nil,
         dismissals: DismissalStore? = nil) {
        self.sessionsDir = sessionsDir
        let titles = titles ?? TitleService()
        let dismissals = dismissals ?? DismissalStore()
        self.titles = titles
        self.dismissals = dismissals
        // A generated title arriving later must repaint the affected card.
        titleObserver = titles.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        dismissalObserver = dismissals.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    private var titleObserver: AnyCancellable?
    private var dismissalObserver: AnyCancellable?

    /// Reference counted: the main window and the mini deck each claim the
    /// watchers independently, so closing one must not blind the other.
    private var claims = 0

    func start() {
        claims += 1
        guard claims == 1 else { return }
        refresh()
        watcher = DirectoryWatcher(paths: [sessionsDir.path]) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        watcher?.start()

        // FSEvents is the fast path; this is a cheap backstop for the rare
        // case where a write is missed (volume remount, editor-style atomic
        // replace on a directory we are not watching recursively).
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Whether the FSEvents subscription is live. Exists so `--selftest` can
    /// prove that closing one window does not blind the other.
    var isWatching: Bool { watcher != nil }

    func stop() {
        claims = max(0, claims - 1)
        guard claims == 0 else { return }
        watcher?.stop()
        watcher = nil
        safetyTimer?.invalidate()
        safetyTimer = nil
    }

    /// Collapse bursts of writes (a status change touches several files) into
    /// one refresh, while staying far below human-perceptible latency.
    private func scheduleRefresh() {
        coalesce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        coalesce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    func refresh() {
        let records = loadRecords()
        var built: [Session] = []
        var handbacks: [Session] = []

        for record in records {
            guard let sessionId = record.sessionId, let cwd = record.cwd else { continue }
            let alive = Self.isAlive(pid: record.pid)
            let activity = Activity(raw: record.status)

            let intent = reader.resolve(sessionId: sessionId, cwd: cwd)

            // A generated title is only consulted when generation is actually
            // warranted. Reading the cache unconditionally let a stale entry
            // override a perfectly good heading.
            var generated: String?
            if intent.wantsGeneratedTitle, let seed = intent.generationSeed {
                titles.requestIfNeeded(sessionId: sessionId, seed: seed)
                generated = titles.summary(for: sessionId, seed: seed)
            }
            let since = Self.date(fromMillis: record.statusUpdatedAt)
                ?? Self.date(fromMillis: record.updatedAt)
                ?? Date()

            var session = Session(
                pid: record.pid,
                sessionId: sessionId,
                cwd: cwd,
                name: record.name ?? String(sessionId.prefix(8)),
                kind: record.kind ?? "interactive",
                agent: record.agent,
                activity: activity,
                isAlive: alive,
                since: since,
                startedAt: Self.date(fromMillis: record.startedAt) ?? since,
                title: intent.best,
                generatedTitle: generated,
                headingTitle: intent.referenceHeading,
                detail: intent.prose ?? intent.command,
                hasTranscript: intent.transcriptFound,
                gitBranch: intent.gitBranch
            )

            // Only meaningful while the process exists to be walked, and only
            // costs a couple of sysctls per live agent.
            if alive {
                session.host = WindowLocator.host(ofAgent: record.pid)
                session.tty = WindowLocator.tty(ofAgent: record.pid)
            }

            // Drop long-dead sessions so the list stays a live picture.
            if !alive, Date().timeIntervalSince(since) > inactiveHorizon { continue }

            session.isDismissed = dismissals.isHidden(sessionId: sessionId, since: since)

            if let was = previousActivity[sessionId],
               was.isWorking, !activity.isWorking, alive {
                handbacks.append(session)
            }
            previousActivity[sessionId] = activity
            built.append(session)
        }

        // Most recently changed first within each lane.
        sessions = built.sorted {
            $0.lane.rawValue == $1.lane.rawValue
                ? $0.since > $1.since
                : $0.lane.rawValue < $1.lane.rawValue
        }
        // Cheap: the reader stats before it parses and throttles the large
        // file, so this rides along on the existing refresh cadence.
        let reading = usageReader.snapshot()
        if usage != reading { usage = reading }

        lastRefresh = Date()
        dismissals.prune(knownSessionIds: Set(built.map(\.sessionId)))
        handbacks.forEach { onHandback?($0) }
    }

    /// Re-derive the list (used when a generated title lands).
    private func rebuild() { refresh() }

    /// Everything not currently cleared from the view.
    var visibleSessions: [Session] { sessions.filter { !$0.isDismissed } }

    /// What the mini deck shows: agents that are mid-turn, plus anything that
    /// has stopped to ask you something.
    ///
    /// A finished agent is deliberately absent — the strip is a "what is
    /// happening" instrument, and a row that lingers after the work is done is
    /// exactly the screen real estate it exists to save. An agent waiting on
    /// you is included because it is the one state you lose money by missing.
    /// Ordering is the store's own: needs-you first, then most recently
    /// changed.
    var activeSessions: [Session] {
        visibleSessions.filter { $0.lane == .needsAttention || $0.lane == .running }
    }

    /// The finished agents a cleanup would clear right now.
    var clearableSessions: [Session] {
        visibleSessions.filter { $0.lane == .finished || $0.lane == .inactive }
    }

    func clearFinished() { dismissals.dismiss(clearableSessions) }

    /// Sessions grouped by project, ordered by the most urgent lane present
    /// then by most recent activity, so whatever needs you floats to the top.
    func byProject(includeInactive: Bool = false) -> [ProjectGroup] {
        let pool = visibleSessions
        let visible = includeInactive ? pool : pool.filter { $0.lane != .inactive }
        let grouped = Dictionary(grouping: visible, by: \.project)
        return grouped.map { name, items in
            ProjectGroup(name: name, sessions: items, cwd: items.first?.cwd ?? name)
        }
        .sorted {
            if $0.topLane != $1.topLane { return $0.topLane.rawValue < $1.topLane.rawValue }
            if $0.latestActivity != $1.latestActivity { return $0.latestActivity > $1.latestActivity }
            return $0.name < $1.name
        }
    }

    func sessions(in lane: Lane) -> [Session] {
        visibleSessions.filter { $0.lane == lane }
    }

    private func loadRecords() -> [SessionRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        var out: [SessionRecord] = []
        var seen: Set<String> = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(SessionRecord.self, from: data),
                  let sessionId = record.sessionId
            else { continue }
            // A resumed session can leave an older pid file behind; keep the
            // most recently updated record per sessionId.
            if seen.contains(sessionId) {
                if let index = out.firstIndex(where: { $0.sessionId == sessionId }),
                   (out[index].updatedAt ?? 0) < (record.updatedAt ?? 0) {
                    out[index] = record
                }
                continue
            }
            seen.insert(sessionId)
            out.append(record)
        }
        return out
    }

    /// `kill(pid, 0)` probes for existence without signalling. EPERM still
    /// means the process is there; only ESRCH means it is gone.
    static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func date(fromMillis millis: Double?) -> Date? {
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
