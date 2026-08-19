import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel

    private var isOpen: Bool { vm.isOpen }
    private var size: CGSize { vm.bodySize }
    private var topRadius: CGFloat { isOpen ? Theme.openTopRadius : Theme.collapsedTopRadius }

    var body: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            NotchShape(
                topRadius: topRadius,
                bottomRadius: isOpen ? Theme.openBottomRadius : Theme.collapsedBottomRadius
            )
            .fill(Color.black)
            .frame(width: size.width + 2 * topRadius, height: size.height)
            .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 18, y: 8)

            VStack(spacing: 0) {
                header
                if isOpen {
                    content
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.openAnimation, value: isOpen)
        .animation(Theme.paneAnimation, value: vm.tab)
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. Nothing interactive goes in
    // this row; the tab switcher lives in the rail below.

    private var header: some View {
        HStack(spacing: 0) {
            if isOpen {
                Text(vm.tab.title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 16)
                    .id(vm.tab)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: vm.geometry.notchSize.width, height: 1)
            Spacer(minLength: 0)
            if isOpen {
                trailing
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .frame(height: vm.geometry.notchSize.height)
    }

    @ViewBuilder
    private var trailing: some View {
        switch vm.tab {
        case .study:
            if vm.study.remainingDue > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                    Text("\(vm.study.remainingDue) due")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
        case .add:
            // Nothing: the pane itself carries the one thing worth saying here,
            // and it says it next to the word it is about.
            EmptyView()
        case .search:
            SearchCounter(search: vm.search)
        case .stats:
            if let streak = vm.stats.stats?.currentStreakDays, streak > 0 {
                Text("\(streak)-day streak")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
        case .settings:
            ConnectionDot(state: vm.session.state)
        }
    }

    // MARK: - Body

    private var content: some View {
        HStack(spacing: 14) {
            Rail(vm: vm)
            panes
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        // The body's height is measured from this same number, so the two
        // cannot drift apart into a rail that does not fit.
        .padding(.bottom, NotchGeometry.bodyBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .scale(scale: 0.97))
                        .animation(Theme.paneIn),
                    removal: .opacity
                        .combined(with: .scale(scale: 1.02))
                        .animation(Theme.paneOut)
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var pane: some View {
        // Every tab but settings needs a server. Saying so once here keeps four
        // panes from each having to grow an "or else" branch, and keeps the one
        // remedy — the settings tab — a single click away rather than a
        // sentence of instructions.
        if vm.session.state.isConnected || vm.tab == .settings {
            switch vm.tab {
            case .study:
                StudyPane(vm: vm)
            case .add:
                AddPane(vm: vm)
            case .search:
                SearchPane(vm: vm)
            case .stats:
                StatsPane(stats: vm.stats)
            case .settings:
                SettingsPane(vm: vm)
            }
        } else {
            DisconnectedPane(vm: vm)
        }
    }
}

/// Watches the search store itself rather than reading through the view model:
/// the view model deliberately does not forward the keystroke-driven stores,
/// and this counter changes on every one of them.
private struct SearchCounter: View {
    @ObservedObject var search: SearchStore

    var body: some View {
        if !search.hits.isEmpty {
            Text(search.exactMatch ? "exact match" : "\(search.hits.count) found")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(search.exactMatch ? Theme.accent : Theme.tertiary)
        }
    }
}

private struct ConnectionDot: View {
    let state: Session.State

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
        }
    }

    private var color: Color {
        switch state {
        case .connected: return Theme.good
        case .connecting: return Theme.hard
        case .failed: return Theme.again
        case .signedOut: return Theme.tertiary
        }
    }

    private var label: String {
        switch state {
        case let .connected(name): return name
        case .connecting: return "connecting"
        case .failed: return "offline"
        case .signedOut: return "not signed in"
        }
    }
}

/// Tab switcher.
///
/// Hovering switches tabs, but only after the pointer has stopped: a pointer
/// crossing the rail on its way somewhere else is gone in a few dozen
/// milliseconds, while one that came to choose stays put. The same dwell
/// threshold separates "the mouse was flung across the top of the screen" from
/// "the mouse came to the notch" in `PointerWatcher`.
private struct Rail: View {
    @ObservedObject var vm: NotchViewModel

    @State private var hovered: NotchViewModel.Tab?

    private let dwell = Duration.milliseconds(150)

    var body: some View {
        VStack(spacing: NotchGeometry.railSpacing) {
            ForEach(NotchViewModel.Tab.allCases) { tab in
                Button {
                    vm.select(tab)
                } label: {
                    ZStack {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .medium))
                        // The due count rides the study icon, so the rail says
                        // what the collection wants without the tab being open.
                        if tab == .study, let due = vm.stats.dueNow, due > 0, vm.tab != .study {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 5, height: 5)
                                .offset(x: 9, y: -7)
                        }
                    }
                    .frame(width: 30, height: vm.geometry.railIconHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(fill(for: tab))
                    )
                    .foregroundStyle(vm.tab == tab ? Theme.ink : Theme.tertiary)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    // A render-time transform. Growing the frame instead would
                    // re-lay out the rail on every hover, and layout that runs
                    // on pointer movement is exactly the kind that shows up as
                    // a stutter.
                    .scaleEffect(hovered == tab ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .onHover { inside in
                    if inside {
                        hovered = tab
                    } else if hovered == tab {
                        hovered = nil
                    }
                }
            }
        }
        .frame(width: 30)
        // Centred in the height an ordinary tab has, then that block pinned to
        // the top of whatever height this tab actually got. On the short tabs
        // the two are the same and nothing moves; on the tall ones the extra
        // 160 pt goes to the list below, and the icons stay put.
        .frame(height: vm.geometry.standardContentHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Theme.contentAnimation, value: hovered)
        // Moving to another icon cancels the pending switch along with the
        // task, so only the icon actually rested on ever wins.
        .task(id: hovered) {
            guard let hovered, hovered != vm.tab else { return }
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            vm.select(hovered)
        }
    }

    private func fill(for tab: NotchViewModel.Tab) -> Color {
        if vm.tab == tab { return Theme.surfaceHover }
        return hovered == tab ? Theme.surface : .clear
    }
}

/// Shown in place of every pane that needs a server, when there is not one.
///
/// One line and one button. The alternative — each pane explaining the same
/// thing in its own words — is four chances to word it differently.
private struct DisconnectedPane: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: message.symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button(message.action) { vm.select(.settings) }
                .buttonStyle(PanelButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: (symbol: String, text: String, action: String) {
        switch vm.session.state {
        case .signedOut:
            return ("key", "Enka needs your access secret before it can show you anything.", "Sign in")
        case .connecting:
            return ("arrow.triangle.2.circlepath", "Connecting…", "Settings")
        case let .failed(message):
            return ("exclamationmark.triangle", message, "Settings")
        case .connected:
            return ("checkmark", "Connected.", "Settings")
        }
    }
}
