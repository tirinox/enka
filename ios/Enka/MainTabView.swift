import SwiftUI

/// Everything the Mac panel does, laid out for a thumb.
///
/// The panel has six tabs because it is a strip of chrome under the notch and a
/// row of icons is free there. A phone pays for each one with a fifth of the
/// bottom bar, so the two that are read rather than used — the tag list and the
/// server settings — are one screen: Settings owns the connection, and the tags
/// are a push away from both it and the cards they belong to.
///
/// What is left is the four things somebody actually opens the app to do:
/// answer a card, add a word, find one, and see how it is going.
struct MainTabView: View {
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var tags: TagStore
    @EnvironmentObject private var capture: CaptureStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: Tab = .study

    enum Tab: Hashable { case study, add, cards, progress, settings }

    var body: some View {
        TabView(selection: $tab) {
            StudyView()
                .tabItem { Label("Study", systemImage: "rectangle.on.rectangle.angled") }
                .tag(Tab.study)
                // The one number that gets somebody to study without deciding
                // to — the phone's version of the Mac's menu bar count. Zero
                // hides it, which is the point: an empty badge is a finished
                // day.
                .badge(stats.dueNow ?? 0)

            AddView()
                .tabItem { Label("Add", systemImage: "plus.circle") }
                .tag(Tab.add)

            CardsView()
                .tabItem { Label("Cards", systemImage: "square.stack") }
                .tag(Tab.cards)

            StatsView()
                .tabItem { Label("Progress", systemImage: "chart.bar") }
                .tag(Tab.progress)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .task {
            // Read once at launch rather than per screen: the names and colours
            // are wanted by the add screen's chips, the filter row and the
            // editor, and they change a few times a month.
            tags.refresh()
            // The badge is the one thing that keeps asking with nobody looking
            // at it, which is what makes it worth having.
            stats.startPolling()
        }
        // The two stores that hold a tag *name* rather than an id have to hear
        // about a rename, or they keep sending the old one — which creates the
        // old tag again, undoing the rename by the back door.
        .onChange(of: tags.tags) { _, current in
            capture.reconcile(with: current)
            library.reconcile(with: current)
        }
        .onChange(of: scenePhase) { _, phase in
            // A phone in a pocket has nothing to poll for. The count is asked
            // for again the moment it comes back, because what moves it is the
            // same collection being answered on the Mac.
            if phase == .active {
                stats.startPolling()
            } else {
                stats.stopPolling()
            }
        }
    }
}
