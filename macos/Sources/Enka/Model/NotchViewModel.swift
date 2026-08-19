import AppKit
import Combine

/// What the panel is showing and everything it is showing it from.
@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case study, add, search, tags, stats, settings
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .study: return "rectangle.on.rectangle.angled"
            case .add: return "plus.circle"
            case .search: return "magnifyingglass"
            case .tags: return "tag"
            case .stats: return "chart.bar"
            case .settings: return "gearshape"
            }
        }

        var title: String {
            switch self {
            case .study: return "Study"
            case .add: return "Add"
            case .search: return "Search"
            case .tags: return "Tags"
            case .stats: return "Progress"
            case .settings: return "Settings"
            }
        }

        /// Tabs with a field in them. Landing on one hands it the keyboard, so
        /// that arriving and typing is a single move.
        ///
        /// Study is pointedly *not* one of them, even though it is the tab with
        /// the most shortcuts. Taking key status dims the caret of whatever the
        /// user is writing in, and study is the tab a stray hover lands on —
        /// it is the default. So study takes the keyboard when it is clicked,
        /// which is also the click that reveals the first card: one press, and
        /// the digits are live from then on.
        var needsKeyboard: Bool { self == .add || self == .search || self == .tags || self == .settings }

        /// The tabs that show a list, and get the taller body for it.
        var isTall: Bool { self == .search || self == .tags || self == .stats }
    }

    @Published var isOpen = false
    @Published var tab: Tab = .study {
        didSet {
            guard tab != oldValue else { return }
            // Each tab is woken on the way in rather than kept warm. Nothing
            // here changes often enough to be worth a subscription, and the
            // study loop in particular must not fetch a card nobody is looking
            // at — `study/next` counts it as shown.
            study.setActive(tab == .study)
            switch tab {
            // Both tabs show the same list, and both are the place it might
            // have gone stale — the add tab's chips are as wrong after a rename
            // in the web client as the tags tab's rows are.
            case .add, .tags: tagStore.refresh()
            case .stats: stats.refresh()
            default: break
            }
            // Leaving the tags tab abandons any half-made edit rather than
            // keeping it warm for a hover that may be days away.
            if oldValue == .tags {
                tagStore.editing = nil
                tagStore.confirmingDelete = nil
            }
            // Leaving a tab that types gives the keyboard straight back.
            if !tab.needsKeyboard { wantsKeyboard = false }
        }
    }

    /// Whether the panel currently holds the keyboard.
    ///
    /// Tracked apart from `tab` because the two come apart in one direction:
    /// clicking into another app drops the claim without changing which tab is
    /// showing, so a half-typed card survives and the panel is free to collapse.
    @Published var wantsKeyboard = false

    let geometry: NotchGeometry
    let session: Session
    let audio: AudioPlayback
    let study: StudySession
    let capture: CaptureStore
    let search: SearchStore
    let tagStore: TagStore
    let stats: StatsStore

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry, session: Session, audio: AudioPlayback, stats: StatsStore) {
        self.geometry = geometry
        self.session = session
        self.audio = audio
        self.stats = stats
        self.study = StudySession(session: session, audio: audio)
        self.capture = CaptureStore(session: session)
        self.search = SearchStore(session: session)
        self.tagStore = TagStore(session: session)

        // The header reads through to the stores — the due counter, the hit
        // count, the connection dot. Nested `ObservableObject`s do not
        // propagate on their own, so those would only refresh when something
        // else happened to redraw the view.
        //
        // Forwarded only while the panel is open: collapsed, the panel is a
        // black shape and these redraws could change nothing, yet the stores
        // keep their own schedule. Opening repaints from the stores directly,
        // because `isOpen` is itself `@Published`.
        //
        // The two stores with a text field in their pane — capture and search —
        // are deliberately absent. They change on every keystroke, and redrawing
        // the whole panel per letter rebuilds the field, which drops the focus:
        // the first letter typed would also be the last one that lands. Their
        // panes observe them directly.
        tagStore.$tags
            .sink { [weak self] tags in self?.capture.reconcile(with: tags) }
            .store(in: &cancellables)

        for child in [session.objectWillChange, study.objectWillChange, stats.objectWillChange, tagStore.objectWillChange] {
            child
                .sink { [weak self] _ in
                    guard let self, self.isOpen else { return }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }

    /// Body this tab takes when open — asked whether it is open yet or not.
    ///
    /// Separate from `bodySize` because the rects are cut one step before the
    /// panel is marked open: the controller grows the interactive area first,
    /// so the pointer never falls through a region the animation has not
    /// covered. Reading a size that returns the notch until `isOpen` flips
    /// would hand that step the collapsed size and leave the whole body drawn
    /// but deaf to the pointer.
    var openBodySize: CGSize {
        tab.isTall ? geometry.tallExpandedSize : geometry.expandedSize
    }

    var bodySize: CGSize {
        isOpen ? openBodySize : geometry.notchSize
    }

    /// Hover and click both land here.
    func select(_ tab: Tab) {
        self.tab = tab
        if tab.needsKeyboard { wantsKeyboard = true }
    }

    /// A click anywhere inside the panel. The study tab earns the keyboard this
    /// way rather than by being hovered — see `Tab.needsKeyboard`.
    func pressedInside() {
        if tab.needsKeyboard || tab == .study { wantsKeyboard = true }
    }

    func start() {
        study.setActive(tab == .study)
    }

    func stop() {
        study.setActive(false)
        audio.stop()
    }
}
