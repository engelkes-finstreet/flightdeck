import SwiftUI
import AppKit

/// The laptop companion to the main window: one line per agent that is
/// actually in flight, and nothing else.
///
/// The main window is built to be read from across a desk on a second
/// display. This is the opposite brief — it has to survive sitting on top of
/// the editor on a 13" screen, so everything that is not a project name is
/// either shrunk to a glyph or moved into the tooltip. What stays is the one
/// question the window exists to answer: which projects have an agent working
/// in them right now, and how long has it been.
struct MiniDeckView: View {
    @ObservedObject var store: SessionStore
    /// Shared with the main window, so ⌘+ / ⌘- carries over to the strip.
    @AppStorage("textScale") private var textScale: Double = 1.0
    var onClose: () -> Void
    var onExpand: () -> Void

    @State private var hoveringChrome = false

    /// Content width before the text-scale multiplier. Sized so a ~20
    /// character project name fits beside the clock and the glyph; longer
    /// names truncate in the middle, where repos differ least.
    static let baseWidth: CGFloat = 208

    private var scale: CGFloat { CGFloat(textScale) }

    var body: some View {
        // One clock for the whole strip rather than one per row.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 1) {
                header
                if store.activeSessions.isEmpty {
                    idle
                } else {
                    ForEach(store.activeSessions) { session in
                        MiniRow(session: session, now: context.date, scale: scale)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(width: Self.baseWidth * scale, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.18))
            )
            .animation(.easeInOut(duration: 0.18), value: store.activeSessions.map(\.id))
        }
    }

    /// Doubles as the drag handle. The buttons only appear under the pointer,
    /// so at rest the strip is just the roster.
    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "airplane.departure")
                .font(.system(size: CGFloat(8.5).scaled(scale)))
                .foregroundStyle(Theme.working)
            Text("\(store.activeSessions.count)")
                .font(.system(size: CGFloat(9).scaled(scale), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if hoveringChrome {
                chromeButton("macwindow", help: "Open the full window", action: onExpand)
                chromeButton("xmark", help: "Hide the mini deck (⇧⌘M)", action: onClose)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .frame(height: CGFloat(13).scaled(scale))
        .contentShape(Rectangle())
        .onHover { hoveringChrome = $0 }
    }

    private func chromeButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: CGFloat(8).scaled(scale), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: CGFloat(13).scaled(scale), height: CGFloat(11).scaled(scale))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var idle: some View {
        Text("nothing in flight")
            .font(.system(size: Theme.Size.mini.scaled(scale)))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
    }
}

/// One in-flight agent. Project name, how long it has been in this state, and
/// the same status glyph the main window uses.
private struct MiniRow: View {
    let session: Session
    let now: Date
    let scale: CGFloat
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            // Same per-project tint as the main window's group headers, so a
            // project you have learned by colour is still recognisable here.
            Circle()
                .fill(Theme.tint(forProject: session.project))
                .frame(width: 5.5, height: 5.5)

            Text(session.project)
                .font(.system(size: Theme.Size.mini.scaled(scale), weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(RelativeTime.short(since: session.since, now: now))
                .font(.system(size: CGFloat(9.5).scaled(scale), design: .rounded))
                .monospacedDigit()
                // An agent waiting on you is the one thing worth a second
                // colour; everything else stays quiet.
                .foregroundStyle(session.lane == .needsAttention ? Theme.attention : .secondary)

            StatusGlyph(activity: session.activity, size: CGFloat(10.5).scaled(scale))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Theme.accent(for: session.lane).opacity(0.16) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { jump() }
        .help(tooltip)
    }

    /// The strip has no room for what the agent is actually doing, so the
    /// tooltip carries it.
    private var tooltip: String {
        var lines = ["\(session.project) · \(session.activity.label)", session.headline]
        if let branch = session.gitBranch, !branch.isEmpty { lines.append("branch \(branch)") }
        if let host = session.host { lines.append("click to jump to \(host.name)") }
        return lines.joined(separator: "\n")
    }

    private func jump() {
        if case .noHost = WindowLocator.jump(to: session) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
        }
    }
}
