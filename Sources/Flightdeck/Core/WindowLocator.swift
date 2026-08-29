import AppKit
import Darwin

/// The GUI application an agent is actually running inside: the WebStorm
/// window with the embedded terminal, the Ghostty tab, the Terminal split.
///
/// Found by walking the agent's process ancestry rather than guessing from the
/// working directory, because the working directory says nothing about where
/// you launched from — several of these can share one WebStorm process.
struct AgentHost: Equatable {
    let pid: pid_t
    let bundleID: String
    /// Display name, e.g. `WebStorm`. What the UI offers to jump to.
    let name: String
    let family: Family

    /// How this host can be asked to show a particular window, which is the
    /// whole of what distinguishes one from another here.
    ///
    /// Every entry is an interface the app publishes on purpose. An earlier
    /// version drove the Window menu through the accessibility API instead,
    /// which reaches every app but crashed WebStorm outright: pressing an
    /// entry only works once the menu has been opened, and opening an AWT menu
    /// bar programmatically kills the process during menu-tracking teardown.
    enum Family: Equatable {
        /// Ghostty publishes an AppleScript dictionary in which every terminal
        /// surface reports its working directory and can be focused directly.
        case ghostty
        /// Terminal.app's tabs expose the tty of the shell running in them,
        /// which is exactly the identity we already have for the agent.
        case terminalApp
        /// iTerm2's sessions expose the same tty.
        case iTerm
        /// JetBrains IDEs and the VS Code family focus the window a project is
        /// already open in when asked to open that path again.
        case projectPath
        case unknown
    }
}

/// What a jump could do for this agent.
enum JumpOutcome: Equatable {
    /// The host app was raised, and a request for the specific window or tab
    /// was dispatched. Reported optimistically: the focusing half runs off the
    /// main thread, because a first request has to wait on the system's
    /// automation prompt.
    case dispatched(AgentHost)
    /// No GUI ancestor — a detached `--bg` agent has no window to show.
    case noHost
}

/// Resolves an agent process to the window it lives in, and goes there.
enum WindowLocator {
    // MARK: - Finding the host

    /// Walk up from the agent until a real GUI application appears.
    ///
    /// The chain is short and boring in practice — `claude` -> `zsh` -> the
    /// app — but nested shells, `login`, and multiplexers add hops, so the
    /// walk is bounded rather than assumed.
    static func host(ofAgent pid: pid_t) -> AgentHost? {
        var current = pid
        for _ in 0..<12 {
            guard let parent = info(for: current)?.kp_eproc.e_ppid, parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent),
               app.activationPolicy == .regular,
               let bundleID = app.bundleIdentifier {
                return AgentHost(pid: parent,
                                 bundleID: bundleID,
                                 name: app.localizedName ?? bundleID,
                                 family: family(for: bundleID))
            }
            current = parent
        }
        return nil
    }

    /// The terminal device the agent is attached to, as `ttys004`. The
    /// identity Terminal.app and iTerm2 use for their tabs.
    static func tty(ofAgent pid: pid_t) -> String? {
        // `e_tdev` is -1 for anything with no controlling terminal, which
        // covers background agents and any process started outside a shell.
        guard let device = info(for: pid)?.kp_eproc.e_tdev, device != -1,
              let name = devname(device, S_IFCHR)
        else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// `sysctl` rather than shelling out to `ps`: this runs on every refresh,
    /// for every agent, and a process spawn per card per FSEvent is not a
    /// price worth paying for information a syscall already has.
    private static func info(for pid: pid_t) -> kinfo_proc? {
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let ok = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &proc, &size, nil, 0) == 0
        }
        // A dead pid returns success with a zeroed record, so the size check
        // is what actually distinguishes "no such process".
        guard ok, size > 0 else { return nil }
        return proc
    }

    private static func family(for bundleID: String) -> AgentHost.Family {
        if bundleID.hasPrefix("com.jetbrains.") || bundleID == "com.google.android.studio" {
            return .projectPath
        }
        switch bundleID {
        case "com.mitchellh.ghostty":    return .ghostty
        case "com.apple.Terminal":       return .terminalApp
        case "com.googlecode.iterm2":    return .iTerm
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
             "com.visualstudio.code.oss", "dev.zed.Zed",
             // Cursor and Windsurf ship under opaque ToDesktop identifiers.
             "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf":
            return .projectPath
        default:
            return .unknown
        }
    }

    // MARK: - Jumping

    /// Go to where this agent is running.
    ///
    /// Activation happens first, synchronously and for every host, so even one
    /// we have no way to introspect still gets you to the right application.
    /// Picking the window out of it is a best effort layered on top.
    @discardableResult
    static func jump(to session: Session) -> JumpOutcome {
        guard let host = session.host,
              let app = NSRunningApplication(processIdentifier: host.pid)
        else { return .noHost }

        app.activate()

        // Off the main thread: the first request to control another app blocks
        // on the system's automation prompt, and a spinning board while the
        // user reads a dialog is not worth the simpler code.
        DispatchQueue.global(qos: .userInitiated).async {
            focusWindow(for: session, host: host)
        }
        return .dispatched(host)
    }

    private static func focusWindow(for session: Session, host: AgentHost) {
        switch host.family {
        case .ghostty:
            focusGhosttyTerminal(for: session)
        case .terminalApp:
            guard let tty = session.tty else { return }
            run(script: """
                tell application "Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(escape(tty))" then
                        set selected of t to true
                        set index of w to 1
                        return
                      end if
                    end repeat
                  end repeat
                end tell
                """)
        case .iTerm:
            guard let tty = session.tty else { return }
            run(script: """
                tell application "iTerm"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "\(escape(tty))" then
                          select w
                          select t
                          select s
                          return
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                """)
        case .projectPath:
            // Asked to open a project it already has open, a JetBrains IDE or
            // a VS Code window comes forward rather than opening it twice.
            //
            // Only ever asked with a directory that is demonstrably a project
            // root. An agent may well have been started deeper in the tree,
            // and handing the IDE a subdirectory does not focus anything — it
            // opens a second project on top of the one you wanted.
            guard let root = projectRoot(for: session.cwd, bundleID: host.bundleID),
                  let bundleURL = NSRunningApplication(processIdentifier: host.pid)?.bundleURL
            else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: root)],
                                    withApplicationAt: bundleURL,
                                    configuration: configuration)
        case .unknown:
            break
        }
    }

    /// The nearest enclosing directory this editor would recognise as a
    /// project, starting at the agent's own working directory.
    ///
    /// `.idea` is written by JetBrains into exactly the directory it considers
    /// the project root, which makes it an unusually reliable marker. The VS
    /// Code family keeps no such thing reliably, so a repository root is the
    /// best available stand-in.
    static func projectRoot(for cwd: String, bundleID: String) -> String? {
        let markers = bundleID.hasPrefix("com.jetbrains.") || bundleID == "com.google.android.studio"
            ? [".idea"]
            : [".vscode", ".git"]
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<24 {
            for marker in markers
            where FileManager.default.fileExists(atPath:
                directory.appendingPathComponent(marker).path) {
                return directory.path
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    // MARK: - Ghostty

    /// One terminal surface out of every tab of every window.
    struct GhosttySurface: Equatable {
        let id: String
        let cwd: String
        let title: String
    }

    /// Ghostty reports each surface's live working directory, so the agent's
    /// own `cwd` identifies its tab outright — no title guessing needed, and
    /// no ambiguity unless two agents genuinely share a directory.
    private static func focusGhosttyTerminal(for session: Session) {
        let surfaces = ghosttySurfaces()
        guard let target = pick(from: surfaces, for: session) else { return }
        run(script: """
            tell application "Ghostty" to focus (first terminal whose id is "\(escape(target.id))")
            """)
    }

    /// The surface this session is running in.
    ///
    /// Working directory is the strong signal. Two agents in one directory
    /// fall back to the title, which is worth trying because Claude Code sets
    /// it — though to its own summary of the task rather than to anything
    /// Flightdeck knows, so it is a fuzzy comparison and may decline.
    static func pick(from surfaces: [GhosttySurface], for session: Session) -> GhosttySurface? {
        let wanted = trimmed(session.cwd)
        let here = surfaces.filter { trimmed($0.cwd) == wanted }
        if here.count == 1 { return here[0] }

        let pool = here.isEmpty ? surfaces : here
        if pool.count == 1 { return pool[0] }
        guard let index = match(titles: pool.map(\.title),
                                to: titleCandidates(for: session))
        else { return nil }
        return pool[index]
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func ghosttySurfaces() -> [GhosttySurface] {
        // One round trip, unit-separated, because a scripting call per surface
        // is slow enough to be felt.
        let listing = run(script: """
            tell application "Ghostty"
              set out to ""
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in terminals of t
                    set out to out & (id of s) & "\\t" & (working directory of s) & "\\t" & (name of s) & "\\n"
                  end repeat
                end repeat
              end repeat
              return out
            end tell
            """)
        return (listing ?? "").split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3 else { return nil }
            return GhosttySurface(id: fields[0], cwd: fields[1],
                                  title: fields[2...].joined(separator: "\t"))
        }
    }

    // MARK: - Title matching

    /// What this session might be called in a terminal's tab title, best guess
    /// first. Claude Code writes that title, so the card's own headline is the
    /// closest thing to it we hold.
    static func titleCandidates(for session: Session) -> [String] {
        var seen: Set<String> = []
        return [session.headingTitle, session.generatedTitle, session.title, session.name]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    /// Which title belongs to this session, when a directory match could not
    /// settle it. Returns nothing rather than a guess: landing in the wrong
    /// tab is worse than landing in the right app.
    static func match(titles: [String], to names: [String]) -> Int? {
        guard !titles.isEmpty else { return nil }
        if titles.count == 1 { return 0 }

        for candidate in names {
            let needle = normalize(candidate)
            guard needle.count >= 3 else { continue }
            if let hit = titles.firstIndex(where: { normalize($0) == needle }) { return hit }
            if needle.count >= 5,
               let hit = titles.firstIndex(where: {
                   let title = normalize($0)
                   return title.contains(needle) || needle.contains(title)
               }) {
                return hit
            }
        }

        // A tab is titled with Claude Code's summary of the task, which is a
        // different sentence about the same thing than the title Flightdeck
        // derived — "Branch commit and push status" against "Is everything
        // commited and pushed on this branch". Nothing matches literally, but
        // the content words do, so score the overlap.
        return bestOverlap(titles: titles, candidates: names)
    }

    /// Highest-scoring title, but only when it is a clear winner. A tie means
    /// two tabs are doing similar work and guessing between them would land
    /// the user somewhere confusing.
    private static func bestOverlap(titles: [String], candidates: [String]) -> Int? {
        let scored = titles.enumerated()
            .map { entry in
                (index: entry.offset,
                 score: candidates.map { overlap(entry.element, $0) }.max() ?? 0)
            }
            .sorted { $0.score > $1.score }
        guard let winner = scored.first, winner.score >= 0.5 else { return nil }
        let runnerUp = scored.dropFirst().first?.score ?? 0
        guard winner.score - runnerUp >= 0.2 else { return nil }
        return winner.index
    }

    /// Share of the tab title's content words that the candidate also uses.
    /// Compared on stems so `commit` matches `commited` and `push` matches
    /// `pushed`, which is most of what separates two summaries of one prompt.
    private static func overlap(_ title: String, _ candidate: String) -> Double {
        let titleWords = contentWords(title)
        guard titleWords.count >= 2 else { return 0 }
        let candidateWords = contentWords(candidate)
        guard !candidateWords.isEmpty else { return 0 }

        let matched = titleWords.filter { word in
            candidateWords.contains { other in
                let shortest = min(word.count, other.count)
                guard shortest >= 4 else { return word == other }
                return word.hasPrefix(other.prefix(shortest)) || other.hasPrefix(word.prefix(shortest))
            }
        }
        guard matched.count >= 2 else { return 0 }
        return Double(matched.count) / Double(titleWords.count)
    }

    /// Words that carry meaning. Both sides are natural-language summaries, so
    /// without this the filler alone would clear any sane threshold.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "at", "by",
        "is", "are", "was", "be", "it", "this", "that", "with", "from", "as",
        "my", "i", "you", "we", "do", "does", "did", "can", "should", "now",
        "right", "all", "up", "out", "so", "if", "not", "no", "yes", "please"
    ]

    private static func contentWords(_ value: String) -> [String] {
        normalize(value).split(separator: " ")
            .map(String.init)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    /// Flatten to lowercase alphanumeric words, which drops the status glyphs
    /// Claude Code prefixes, em dashes, and the punctuation each host chooses
    /// differently.
    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let flattened = folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(flattened).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Scripting

    @discardableResult
    private static func run(script source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        // Refusing automation, or a terminal that has since closed, is an
        // ordinary outcome here: the app is already frontmost either way.
        if error != nil { return nil }
        return result.stringValue
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Diagnostics

    /// What a click would do, without doing it. Backs `Flightdeck --locate`,
    /// which is the only way to check targeting without stealing the focus you
    /// are trying to observe.
    static func explain(_ session: Session) -> String {
        let label = session.name.padding(toLength: 24, withPad: " ", startingAt: 0)
        guard let host = session.host else { return "\(label) no GUI host (background agent)" }
        let head = "\(label) \(host.name)"

        switch host.family {
        case .ghostty:
            guard let target = pick(from: ghosttySurfaces(), for: session) else {
                return "\(head) — app only, no terminal matched"
            }
            return "\(head) — terminal \"\(target.title)\" in \(target.cwd)"
        case .terminalApp, .iTerm:
            guard let tty = session.tty else { return "\(head) — app only, no tty" }
            return "\(head) — tab on \(tty)"
        case .projectPath:
            guard let root = projectRoot(for: session.cwd, bundleID: host.bundleID) else {
                return "\(head) — app only, no project root above \(session.cwd)"
            }
            return "\(head) — window for \(root)"
        case .unknown:
            return "\(head) — app only (no supported way to pick a window)"
        }
    }
}
