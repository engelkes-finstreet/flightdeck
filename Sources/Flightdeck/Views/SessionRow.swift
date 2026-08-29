import SwiftUI
import AppKit

/// One agent card: what it is working on, on which branch, and how long since
/// it last changed state.
///
/// The project name deliberately lives on the group header rather than here —
/// repeating it on every card wastes the width this column does not have.
struct SessionRow: View {
    let session: Session
    /// Offered only for agents that are actually finished — dismissing a
    /// working agent would just bounce back the moment it changed state.
    var onDismiss: (() -> Void)?
    @Environment(\.textScale) private var textScale
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Lane colour stays on the card so status survives project grouping.
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.accent(for: session.lane))
                .frame(width: 3.5)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(session.headline)
                    .font(.system(size: Theme.Size.headline.scaled(textScale)))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    Text(session.activity.label)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.accent(for: session.lane))
                    if let branch = session.gitBranch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if session.kind == "bg" {
                        Label("background", systemImage: "moon.fill")
                            .foregroundStyle(Theme.working)
                    }
                }
                .font(.system(size: Theme.Size.meta.scaled(textScale)))
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 6) {
                // Re-renders once a second so the stamp stays honest.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(RelativeTime.ago(since: session.since, now: context.date))
                        .font(.system(size: Theme.Size.timestamp.scaled(textScale), design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                StatusGlyph(activity: session.activity, size: Theme.Size.glyph.scaled(textScale))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.card)
                .shadow(color: .black.opacity(hovering ? 0.11 : 0.05), radius: hovering ? 4 : 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(hovering ? Theme.accent(for: session.lane).opacity(0.5) : Theme.hairline)
        )
        .opacity(session.isAlive ? 1 : 0.6)
        .onHover { hovering = $0 }
        .onTapGesture { jump() }
        .contextMenu {
            if let host = session.host {
                Button("Jump to \(host.name)") { jump() }
            }
            Button("Open Project Folder") { reveal() }
            Button("Copy Session ID") { copy(session.sessionId) }
            Button("Copy Attach Command") { copy("claude attach \(session.sessionId.prefix(8))") }
            if let onDismiss, session.lane == .finished || session.lane == .inactive {
                Divider()
                Button("Clear From Flightdeck", action: onDismiss)
            }
        }
        .help(tooltip)
    }

    /// The card is terse; the tooltip carries the full request and identifiers.
    private var tooltip: String {
        var lines = ["\(session.name) · pid \(session.pid) · \(session.activity.label)", session.cwd]
        if let host = session.host {
            lines.append("click to jump to \(host.name)")
        }
        if let detail = session.detail, detail != session.headline {
            lines.append("")
            lines.append(String(detail.prefix(400)))
        }
        return lines.joined(separator: "\n")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func reveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }

    /// Go to where this agent is actually running. A background agent has no
    /// window, so the click falls back to the one place it does exist on
    /// screen — its project folder.
    private func jump() {
        if case .noHost = WindowLocator.jump(to: session) { reveal() }
    }
}
