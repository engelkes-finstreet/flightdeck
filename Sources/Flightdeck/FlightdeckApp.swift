import SwiftUI
import AppKit

@main
struct FlightdeckApp: App {
    @StateObject private var store = SessionStore()
    /// The floating strip for laptop days. Lives outside the Scene graph
    /// because it needs AppKit-level window behaviour — see MiniDeckController.
    @StateObject private var mini = MiniDeckController()
    /// Keep the window above editors so it stays readable on a second display.
    @AppStorage("floatOnTop") private var floatOnTop = true
    /// Multiplier on every point size, so the window can be read from across
    /// a desk. Persisted; adjust with the View menu or ⌘+ / ⌘- / ⌘0.
    @AppStorage("textScale") private var textScale: Double = 1.0

    private static let scaleRange: ClosedRange<Double> = 0.85...1.6

    init() {
        // `Flightdeck --dump` prints the computed roster and exits, so the data
        // layer can be verified without looking at the window.
        // `--jump <name>` drives the same path a click does, from a terminal.
        // Useful on its own, and the only way to check that pressing a window
        // menu entry really moves focus.
        if let index = CommandLine.arguments.firstIndex(of: "--jump"),
           index + 1 < CommandLine.arguments.count {
            let wanted = CommandLine.arguments[index + 1]
            MainActor.assumeIsolated {
                let store = SessionStore()
                store.refresh()
                guard let session = store.sessions.first(where: {
                    $0.isAlive && ($0.name == wanted || $0.project == wanted)
                }) else {
                    print("no live session named \(wanted)")
                    exit(1)
                }
                print(WindowLocator.explain(session))
                switch WindowLocator.jump(to: session) {
                case .dispatched(let host): print("-> raised \(host.name)")
                case .noHost:               print("-> no GUI host")
                }
            }
            // The press is deferred past activation, so let the run loop turn.
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            exit(0)
        }
        if CommandLine.arguments.contains("--locate") {
            MainActor.assumeIsolated {
                let store = SessionStore()
                store.refresh()
                for session in store.sessions where session.isAlive {
                    print(WindowLocator.explain(session))
                }
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run() }
        }
        if CommandLine.arguments.contains("--dump") {
            MainActor.assumeIsolated {
                let store = SessionStore()
                store.refresh()
                // Generation is async and detached; give it a bounded window
                // to land so --dump reflects the real end state.
                let deadline = Date().addingTimeInterval(90)
                var settled = 0
                while Date() < deadline, settled < 2 {
                    store.refresh()
                    settled = store.titles.isGenerating ? 0 : settled + 1
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
                store.refresh()
                if let usage = store.usage {
                    let age = RelativeTime.ago(since: usage.measuredAt)
                    let origin = usage.source.isLive ? "status line" : "~/.claude.json cache"
                    print("usage  (\(origin), measured \(age))")
                    for (label, window) in [("5h", usage.fiveHour), ("week", usage.sevenDay)] {
                        guard let window else { print("  \(label)    no reading"); continue }
                        let reset = window.hasReset(by: Date())
                            ? "window already reset"
                            : window.resetsAt.map { "resets in \(UsageStrip.until($0, now: Date()))" }
                                ?? "reset time unknown"
                        print("  \(label.padding(toLength: 6, withPad: " ", startingAt: 0))"
                              + "\(Int(window.percent.rounded()))%  \(reset)")
                    }
                } else {
                    print("usage  no reading on disk")
                }
                for group in store.byProject(includeInactive: true) {
                    print("\n\(group.name)  [\(group.sessions.count)]")
                    for session in group.sessions {
                        let stamp = RelativeTime.ago(since: session.since)
                        let generated = session.generatedTitle != nil ? " (generated)" : ""
                        print("  \(session.activity.label.padding(toLength: 11, withPad: " ", startingAt: 0))"
                              + " \(stamp.padding(toLength: 8, withPad: " ", startingAt: 0))"
                              + " \(session.gitBranch ?? "-")\(generated)")
                        print("      \(session.headline.prefix(92))")
                    }
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("Flightdeck", id: "flightdeck") {
            FlightdeckView(store: store, mini: mini)
                .environment(\.textScale, CGFloat(textScale))
                .background(WindowConfigurator(floating: floatOnTop))
                .onAppear {
                    store.start()
                    mini.restoreIfPreviouslyOpen(store: store)
                }
                .onDisappear { store.stop() }
        }
        .defaultSize(width: 440, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle("Float Above Other Windows", isOn: $floatOnTop)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button(mini.isVisible ? "Hide Mini Deck" : "Show Mini Deck") {
                    mini.toggle(store: store)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Refresh Now") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Clear Done Agents") { store.clearFinished() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(store.clearableSessions.isEmpty)
                Button("Undo Clear") { store.dismissals.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.dismissals.canUndo)
                Button("Show All Cleared") { store.dismissals.restoreAll() }
                    .disabled(store.dismissals.hiddenCount == 0)

                Divider()

                Button("Bigger Text") { adjustScale(by: 0.1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { adjustScale(by: -0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { textScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
    private func adjustScale(by delta: Double) {
        let next = (textScale + delta).rounded(toPlaces: 2)
        textScale = min(max(next, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

/// Owns the one Flightdeck window so menu commands can drive AppKit
/// behaviour the Scene API does not expose.
///
/// Two things here are load-bearing for parking Flightdeck beside another app
/// on a second display:
///
/// - `.fullScreenPrimary` is what makes full screen possible at all.
///   `NSWindow.toggleFullScreen` is a silent no-op without it, and the window
///   AppKit hands SwiftUI does not have it — which is why the green button and
///   View ▸ Enter Full Screen did nothing. `.fullScreenAllowsTiling` is the
///   separate opt-in for sharing that space with another app in Split View.
/// - Floating is suspended while full screen. It does not block full screen,
///   but a floating window tiled next to Slack would draw on top of it
///   instead of beside it. The preference is restored on the way out.
@MainActor
final class WindowCoordinator {
    static let shared = WindowCoordinator()

    private weak var window: NSWindow?
    /// The user's preference, which survives a trip through full screen.
    private var wantsFloat = true
    private var isFullScreen = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func adopt(_ window: NSWindow, floating: Bool) {
        wantsFloat = floating
        if self.window !== window {
            self.window = window
            isFullScreen = window.styleMask.contains(.fullScreen)
            observe(window)
        }
        apply()
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification,
                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isFullScreen = true
                    self?.apply()
                }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isFullScreen = false
                    self?.apply()
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            },
        ]
    }

    private func apply() {
        guard let window else { return }

        // Resizable is a hard requirement for full screen and for macOS
        // tiling ("Move & Resize", or dragging to a screen edge).
        window.styleMask.insert(.resizable)

        var behavior = window.collectionBehavior
        behavior.remove(.fullScreenNone)
        // Following the active space fights the whole point of parking the
        // window on the display where Slack lives.
        behavior.remove(.moveToActiveSpace)
        // Primary: gets its own full-screen space. AllowsTiling: can share
        // that space with another app in Split View.
        behavior.insert(.fullScreenPrimary)
        behavior.insert(.fullScreenAllowsTiling)
        window.collectionBehavior = behavior

        // Float only while Flightdeck is in the background — the only time
        // floating actually does anything — and never in full screen.
        //
        // A window above `.normal` level does not get a real full screen: it
        // zooms to fill the desktop it is already on instead of taking a space
        // of its own, and macOS will not tile it beside another app. Every
        // window-management gesture (green button, its tiling menu, ⌃⌘F,
        // Move & Resize) happens while the app is active, so dropping to
        // `.normal` for exactly that time costs nothing and lets floating stay
        // switched on without breaking any of them.
        let floatNow = wantsFloat
            && !isFullScreen
            && !window.styleMask.contains(.fullScreen)
            && !NSApp.isActive
        window.level = floatNow ? .floating : .normal

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        if ProcessInfo.processInfo.environment["FLIGHTDECK_WINDOW_DEBUG"] != nil {
            NSLog("FD behavior=%lu level=%ld styleMask=%lu resizable=%d zoomEnabled=%d",
                  window.collectionBehavior.rawValue, window.level.rawValue,
                  window.styleMask.rawValue, window.styleMask.contains(.resizable) ? 1 : 0,
                  window.standardWindowButton(.zoomButton)?.isEnabled == true ? 1 : 0)
        }
    }
}

/// Hands the window to the coordinator as soon as SwiftUI has one.
private struct WindowConfigurator: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { adopt(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        adopt(nsView.window)
    }

    private func adopt(_ window: NSWindow?) {
        guard let window else { return }
        MainActor.assumeIsolated {
            WindowCoordinator.shared.adopt(window, floating: floating)
        }
    }
}
