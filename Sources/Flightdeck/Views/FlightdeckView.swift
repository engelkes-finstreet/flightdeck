import SwiftUI

/// The whole window: agents grouped by project, ordered so that whatever needs
/// you sits at the top. Built to be parked on a second display and read at a
/// glance — which is why the type is sized for distance, not density.
struct FlightdeckView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var mini: MiniDeckController
    @Environment(\.textScale) private var textScale
    @State private var showInactive = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Projects flow into as many columns as the width allows, so
                    // the window reads as a board when it is full screen or
                    // tiled beside another app, and as the original single
                    // column at its default 440pt. A card wider than `maximum`
                    // just wastes the width on stretched text.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330 * textScale,
                                                           maximum: 520 * textScale),
                                                 spacing: 16, alignment: .top)],
                              alignment: .leading,
                              spacing: 18) {
                        ForEach(store.byProject(includeInactive: showInactive)) { group in
                            projectSection(group)
                        }
                    }

                    if !store.sessions(in: .inactive).isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { showInactive.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Text(showInactive ? "Hide inactive" : "Show inactive")
                                Image(systemName: showInactive ? "arrow.up" : "arrow.right")
                            }
                            .font(.system(size: Theme.Size.meta.scaled(textScale)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }

                    if store.visibleSessions.isEmpty { emptyState }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 16)
            }

            footer
        }
        .background(Theme.canvas)
        .frame(minWidth: 340, idealWidth: 440, minHeight: 340)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "airplane.departure")
                .font(.system(size: CGFloat(14).scaled(textScale)))
                .foregroundStyle(Theme.working)
            Text("Flightdeck")
                .font(.system(size: CGFloat(15).scaled(textScale), weight: .semibold, design: .rounded))

            Spacer()

            // The strip is only discoverable from the View menu otherwise,
            // and it is the feature you want on the day you are not at the
            // desk this window was designed for.
            Button {
                mini.toggle(store: store)
            } label: {
                Image(systemName: mini.isVisible ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                    .font(.system(size: CGFloat(12).scaled(textScale)))
                    .foregroundStyle(mini.isVisible ? Theme.working : .secondary)
            }
            .buttonStyle(.plain)
            .help(mini.isVisible
                  ? "Hide the floating mini deck (⇧⌘M)"
                  : "Show a small always-on-top strip of the agents in flight (⇧⌘M)")

            countPill(store.sessions(in: .needsAttention).count, tint: Theme.attention)
            countPill(store.sessions(in: .running).count, tint: Theme.working)
            countPill(store.sessions(in: .finished).count, tint: Theme.done)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func countPill(_ count: Int, tint: Color) -> some View {
        if count > 0 {
            let side = CGFloat(22).scaled(textScale)
            Text("\(count)")
                .font(.system(size: Theme.Size.count.scaled(textScale), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(minWidth: side, minHeight: side)
                .background(Circle().fill(tint.opacity(0.18)))
        }
    }

    /// A project and its agents. Agents keep the global ordering — most
    /// urgent lane first, then most recently changed — so within a project you
    /// still read "needs you" before "running" before "done".
    private func projectSection(_ group: ProjectGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.tint(forProject: group.name))
                    .frame(width: 8, height: 8)
                Text(group.name)
                    .font(.system(size: Theme.Size.projectHeader.scaled(textScale),
                                  weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                laneCount(group.attentionCount, tint: Theme.attention, symbol: "bell.fill")
                laneCount(group.workingCount, tint: Theme.working, symbol: "circle.dotted")
                laneCount(group.doneCount, tint: Theme.done, symbol: "checkmark")
            }
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.sessions) { session in
                    SessionRow(session: session) {
                        store.dismissals.dismiss([session])
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: group.sessions.map(\.id))
    }

    @ViewBuilder
    private func laneCount(_ count: Int, tint: Color, symbol: String) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: CGFloat(9).scaled(textScale)))
                Text("\(count)")
                    .font(.system(size: Theme.Size.count.scaled(textScale),
                                  weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.16)))
        }
    }

    private var emptyState: some View {
        let hidden = store.dismissals.hiddenCount
        return VStack(spacing: 8) {
            Image(systemName: hidden > 0 ? "checkmark.circle" : "moon.zzz")
                .font(.system(size: CGFloat(26).scaled(textScale)))
                .foregroundStyle(.tertiary)
            Text(hidden > 0 ? "All caught up" : "No Claude Code sessions running")
                .font(.system(size: Theme.Size.headline.scaled(textScale)))
                .foregroundStyle(.secondary)
            if hidden > 0 {
                Button("Show \(hidden) cleared") { store.dismissals.restoreAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: Theme.Size.meta.scaled(textScale)))
                    .foregroundStyle(Theme.working)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    /// The usage strip and the live/cleanup row share one footer slab, so the
    /// bottom of the window reads as a single instrument panel.
    private var footer: some View {
        VStack(spacing: 0) {
            if let usage = store.usage {
                UsageStrip(snapshot: usage)
                Divider().overlay(Theme.hairline).padding(.horizontal, 15)
            }
            statusRow
        }
        .background(Theme.card.opacity(0.6))
        .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
        .animation(.easeInOut(duration: 0.2), value: store.usage == nil)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.done)
                .frame(width: 6, height: 6)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("live · \(RelativeTime.ago(since: store.lastRefresh, now: context.date))")
                    .monospacedDigit()
            }

            Spacer(minLength: 6)

            if store.dismissals.hiddenCount > 0 {
                Button {
                    store.dismissals.restoreAll()
                } label: {
                    Text("\(store.dismissals.hiddenCount) hidden")
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show every cleared agent again")
            }

            if store.dismissals.canUndo {
                Button {
                    store.dismissals.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.working)
                .help("Bring back the agents just cleared")
            } else if !store.clearableSessions.isEmpty {
                Button {
                    store.clearFinished()
                } label: {
                    Label("Clear \(store.clearableSessions.count) done", systemImage: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.done)
                .help("Hide finished agents. Processes keep running, and a card"
                      + " returns the moment its agent does anything again.")
            }
        }
        .font(.system(size: Theme.Size.footer.scaled(textScale)))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .animation(.easeInOut(duration: 0.15), value: store.dismissals.hiddenCount)
    }
}
