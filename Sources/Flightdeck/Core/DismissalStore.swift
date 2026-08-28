import Foundation

/// Remembers which finished agents you have cleared from the view.
///
/// Cleanup here means *dismiss*, never *kill*. Flightdeck observes; it does
/// not manage work. An idle session is a session you may well continue
/// tomorrow, so clearing a card must not cost you the agent.
///
/// The mechanic that makes this safe: a dismissal is recorded against the
/// session's state *at the moment you cleared it*. The card stays hidden only
/// while nothing has happened since. The instant the agent does anything —
/// you continue it, it starts working, it asks you something — its
/// `statusUpdatedAt` advances past the dismissal and the card comes straight
/// back, in whichever lane it now belongs to. Continuing a cleaned-up session
/// is therefore not a special case at all; it is the same comparison.
@MainActor
final class DismissalStore: ObservableObject {
    struct Dismissal: Codable {
        /// The session's activity timestamp when it was cleared. Anything
        /// newer than this means the agent moved on and must resurface.
        let sinceEpoch: Double
        let dismissedAt: Date
    }

    @Published private(set) var dismissals: [String: Dismissal] = [:]
    /// The last batch cleared, for undo.
    @Published private(set) var undoable: [String] = []

    private let storeURL: URL
    private var undoTimer: Timer?
    /// How long the undo affordance stays offered.
    private let undoWindow: TimeInterval = 10
    /// Records for sessions that no longer exist are dropped after this.
    private let pruneAfter: TimeInterval = 60 * 60 * 24 * 7

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Flightdeck")
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.storeURL = support.appendingPathComponent("dismissed.json")
        }
        load()
    }

    var hiddenCount: Int { dismissals.count }
    var canUndo: Bool { !undoable.isEmpty }

    /// True if this session should stay out of the list.
    func isHidden(sessionId: String, since: Date) -> Bool {
        guard let dismissal = dismissals[sessionId] else { return false }
        // A hair of tolerance so float round-tripping cannot un-hide a card
        // that has genuinely not changed.
        return since.timeIntervalSince1970 <= dismissal.sinceEpoch + 0.001
    }

    func dismiss(_ sessions: [Session]) {
        guard !sessions.isEmpty else { return }
        for session in sessions {
            dismissals[session.sessionId] = Dismissal(
                sinceEpoch: session.since.timeIntervalSince1970,
                dismissedAt: Date()
            )
        }
        undoable = sessions.map(\.sessionId)
        persist()
        startUndoWindow()
    }

    func undo() {
        guard !undoable.isEmpty else { return }
        for sessionId in undoable { dismissals.removeValue(forKey: sessionId) }
        undoable = []
        undoTimer?.invalidate()
        persist()
    }

    /// Bring everything back, however long ago it was cleared.
    func restoreAll() {
        guard !dismissals.isEmpty else { return }
        dismissals.removeAll()
        undoable = []
        undoTimer?.invalidate()
        persist()
    }

    /// Drop records for sessions that have been gone a long time, so the file
    /// does not grow without bound.
    func prune(knownSessionIds: Set<String>) {
        let cutoff = Date().addingTimeInterval(-pruneAfter)
        let stale = dismissals.filter { id, dismissal in
            !knownSessionIds.contains(id) && dismissal.dismissedAt < cutoff
        }
        guard !stale.isEmpty else { return }
        for id in stale.keys { dismissals.removeValue(forKey: id) }
        persist()
    }

    private func startUndoWindow() {
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: undoWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.undoable = [] }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: Dismissal].self, from: data)
        else { return }
        dismissals = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(dismissals) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
