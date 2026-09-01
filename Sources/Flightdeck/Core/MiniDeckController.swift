import SwiftUI
import AppKit
import Combine

/// Owns the floating mini deck panel.
///
/// This is not a second SwiftUI `Window` scene on purpose. Three things the
/// laptop case needs are only reachable through AppKit:
///
/// - It has to stay above whatever you are typing in, including while
///   Flightdeck is in the background. The main window deliberately drops to
///   `.normal` while the app is active so it can be full-screened and tiled;
///   the strip never wants that and simply stays at `.floating`.
/// - `.canJoinAllSpaces` plus `.fullScreenAuxiliary` is what lets it sit over
///   a terminal that is itself full screen — the usual shape of working on one
///   display.
/// - `.nonactivatingPanel` means clicking a row hands focus straight to the
///   terminal the agent runs in, instead of bouncing through Flightdeck first.
@MainActor
final class MiniDeckController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false

    private var panel: NSPanel?
    /// Held so the strip can release its claim on the store's watchers when
    /// it closes, even if the main window is long gone.
    private weak var store: SessionStore?
    /// Whether the strip is currently holding a claim on the store's watchers.
    private var holdsStoreClaim = false
    /// Re-check the strip's position when the roster changes, and when the
    /// text scale does — both change its size.
    private var rosterObserver: AnyCancellable?
    private var scaleObserver: NSKeyValueObservation?

    /// Persisted top-left corner. NSWindow's own frame autosave is not used:
    /// it records the frame AppKit first cascaded the panel to rather than the
    /// one we place it at, and it saves a bottom-left origin, which is the
    /// corner that moves every time the roster changes height.
    private static let originKey = "miniDeckTopLeft"
    /// Whether the strip was open when the app last quit.
    private static let visibilityKey = "miniDeckVisible"

    func toggle(store: SessionStore) {
        isVisible ? hide() : show(store: store)
    }

    /// Reopen the strip if it was open last time. Called once the main window
    /// is up, so both are driven by the same store.
    func restoreIfPreviouslyOpen(store: SessionStore) {
        guard UserDefaults.standard.bool(forKey: Self.visibilityKey) else { return }
        show(store: store)
    }

    func show(store: SessionStore) {
        let isFirstShow = panel == nil
        let panel = self.panel ?? makePanel(for: store)
        self.panel = panel

        // The store's watchers are reference counted, so the strip keeps the
        // data live even if the main window is closed. Claimed once, however
        // many times `show` is called.
        if !holdsStoreClaim {
            store.start()
            self.store = store
            holdsStoreClaim = true
        }
        observeSizeChanges(of: store)

        // Shown transparent on the very first pass, so the strip is never seen
        // at the position AppKit cascaded it to before it has been placed.
        if isFirstShow { panel.alphaValue = 0 }
        // Regardless: the strip appears even when Flightdeck is not the active
        // app, which is the only way it is ever used.
        panel.orderFrontRegardless()
        if isFirstShow { placeWhenSized(panel) }
        isVisible = true
        UserDefaults.standard.set(true, forKey: Self.visibilityKey)
    }

    func hide() {
        // `close()` rather than `orderOut(nil)`: the panel is not released on
        // close (see `makePanel`), so it can simply be ordered front again,
        // and close is the one that reliably takes a floating all-spaces panel
        // off the screen.
        panel?.close()
        rosterObserver = nil
        scaleObserver = nil
        if holdsStoreClaim {
            store?.stop()
            holdsStoreClaim = false
        }
        isVisible = false
        UserDefaults.standard.set(false, forKey: Self.visibilityKey)
    }

    /// Built once and kept, ordered in and out rather than torn down. Closing
    /// the panel and rebuilding it left a stray window behind on every toggle
    /// — an ordered-out NSWindow is still owned by the application, and
    /// clearing its `contentViewController` brings a fresh, empty one back
    /// onto the screen.
    private func makePanel(for store: SessionStore) -> NSPanel {
        let hosting = NSHostingController(rootView: MiniDeckView(
            store: store,
            onClose: { [weak self] in self?.hide() },
            onExpand: { [weak self] in self?.openMainWindow() }
        ))
        // No sizing options. The hosting *view* already resizes its window to
        // fit the roster, and does it with `setContentSize`, which grows the
        // window downwards from its top-left — exactly what a strip pinned
        // under the menu bar wants. Adding the controller's
        // `.preferredContentSize` on top of that gives two things driving the
        // same frame: on a borderless panel they never agree, and two size
        // changes in quick succession recursed through layout until the stack
        // ran out. Reproducible with ⌘+ pressed twice.
        hosting.sizingOptions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: MiniDeckView.baseWidth, height: 80),
            // Borderless, so the window's frame *is* the card. A titled panel
            // adds a titlebar's height to the frame even with
            // `.fullSizeContentView`, which on a strip this small is a third
            // of it again in transparent dead space above the content.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = "Mini Deck"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Instant, not faded: this is a keystroke toggle, and a fade also
        // muddies whether the window is really off the screen yet.
        panel.animationBehavior = .none
        panel.isRestorable = false
        panel.delegate = self

        self.panel = panel
        return panel
    }

    /// Put the strip where the user left it, or — the first time — at the top
    /// right of the screen, tucked under the menu bar and out of the way of
    /// both the Dock and where editors put their own chrome.
    ///
    /// Deferred until the panel has been shown once: SwiftUI sizes the window
    /// from its content, and until that has happened the frame is empty, so
    /// "18pt in from the right edge" is measured against a zero width and
    /// lands off the screen.
    private func placeWhenSized(_ panel: NSPanel, attempt: Int = 0) {
        guard panel.frame.width > 1 else {
            guard attempt < 20 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.placeWhenSized(panel, attempt: attempt + 1)
            }
            return
        }
        guard let visible = Self.anchorScreen(for: panel)?.visibleFrame else { return }
        let size = panel.frame.size
        let topLeft = Self.savedTopLeft()
            ?? CGPoint(x: visible.maxX - size.width - 18, y: visible.maxY - 18)
        move(panel, to: Self.clamp(CGPoint(x: topLeft.x, y: topLeft.y - size.height),
                                   size: size, into: visible))
        panel.alphaValue = 1
    }

    /// The screen the strip belongs to. `NSWindow.screen` is nil while the
    /// window is off screen, and `NSScreen.main` is nil whenever this app has
    /// no key window — which, for a background app driving a non-activating
    /// panel, is most of the time.
    private static func anchorScreen(for panel: NSPanel) -> NSScreen? {
        panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Keeps the whole strip on the screen it is anchored to, whatever the
    /// roster does to its height.
    private static func clamp(_ origin: CGPoint, size: CGSize, into visible: NSRect) -> CGPoint {
        let inset: CGFloat = 6
        let maxX = max(visible.minX + inset, visible.maxX - size.width - inset)
        let maxY = max(visible.minY + inset, visible.maxY - size.height - inset)
        return CGPoint(x: min(max(origin.x, visible.minX + inset), maxX),
                       y: min(max(origin.y, visible.minY + inset), maxY))
    }

    private static func savedTopLeft() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard let pair = defaults.array(forKey: originKey) as? [Double], pair.count == 2
        else { return nil }
        return CGPoint(x: pair[0], y: pair[1])
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .first { !($0 is NSPanel) && $0.canBecomeMain }?
            .makeKeyAndOrderFront(nil)
    }

    // MARK: - Position

    /// Set while we are the ones moving the window, so a correction of ours is
    /// not mistaken for the user repositioning it.
    private var isAnchoring = false

    func windowDidMove(_ notification: Notification) {
        guard !isAnchoring else { return }
        persistPosition()
    }

    /// Height follows the roster, and AppKit grows a window downwards from its
    /// top-left when the content view is resized — which is what this strip
    /// wants. All that is left to do is keep a long roster from running off
    /// the bottom of the screen, and that has to happen outside the layout
    /// pass: moving the window from inside one re-enters SwiftUI's own window
    /// sizing and recurses until the stack runs out.
    private func observeSizeChanges(of store: SessionStore) {
        rosterObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.keepOnScreen() }
        }
        scaleObserver = UserDefaults.standard.observe(\.textScale, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.keepOnScreen() } }
        }
    }

    private func keepOnScreen() {
        guard let panel, panel.isVisible,
              let visible = Self.anchorScreen(for: panel)?.visibleFrame else { return }
        let clamped = Self.clamp(panel.frame.origin, size: panel.frame.size, into: visible)
        guard clamped != panel.frame.origin else { return }
        move(panel, to: clamped)
    }

    private func move(_ panel: NSPanel, to origin: CGPoint) {
        isAnchoring = true
        panel.setFrameOrigin(origin)
        isAnchoring = false
        persistPosition()
    }

    private func persistPosition() {
        guard let panel, panel.frame.width > 1 else { return }
        UserDefaults.standard.set([panel.frame.minX, panel.frame.maxY], forKey: Self.originKey)
    }
}

/// KVO needs a keypath, and `@AppStorage` writes go through `UserDefaults`.
private extension UserDefaults {
    @objc dynamic var textScale: Double { double(forKey: "textScale") }
}
