import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Built here rather than inside the panel, and held for the life of the
    /// process. The panel is torn down and rebuilt whenever the display
    /// arrangement changes; the session must not be, or plugging in a monitor
    /// would sign the user out.
    private let session = Session()
    private let audio = AudioPlayback()
    private lazy var stats = StatsStore(session: session)

    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchController(session: session, audio: audio, stats: stats)
        controller.install()
        self.controller = controller

        installStatusItem()

        Task {
            await session.restore()
            // Polling starts only once there is somebody to poll for. Started
            // unconditionally it would spend the first five minutes of every
            // signed-out launch asking a server it cannot authenticate to.
            if session.state.isConnected {
                stats.startPolling()
            }
        }

        // The badge follows the count, and the count follows the session.
        stats.$dueNow
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)

        session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.refreshStatusItem()
                if state.isConnected {
                    self.stats.startPolling()
                } else {
                    self.stats.stopPolling()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .enkaBadgePreferenceChanged)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)

        // Coming back from sleep, the count on screen is as old as the sleep
        // was. Re-asking costs one request and is the difference between a
        // badge and a stale badge.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session.state.isConnected else { return }
                Task { await self.stats.refreshDue() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
        stats.stopPolling()
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "character.book.closed",
            accessibilityDescription: "Enka"
        )
        item.button?.image?.isTemplate = true
        item.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        rebuildMenu()
        refreshStatusItem()
    }

    /// The count rides the status item, not a separate window: it is the one
    /// thing that gets somebody to study without having decided to, and the
    /// menu bar is where they will see it without looking.
    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let due = stats.dueNow ?? 0
        if Preferences.badgeShowsDue, session.state.isConnected, due > 0 {
            button.title = " \(due)"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        } else {
            button.title = ""
        }
        button.toolTip = tooltip
    }

    private var tooltip: String {
        switch session.state {
        case .signedOut: return "Enka — not signed in"
        case .connecting: return "Enka — connecting"
        case .failed: return "Enka — cannot reach the server"
        case .connected:
            guard let due = stats.dueNow else { return "Enka" }
            return due == 0 ? "Enka — nothing due" : "Enka — \(due) due"
        }
    }

    /// Rebuilt when the menu opens rather than kept fresh in between: a menu
    /// nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        guard session.state.isConnected else { return }
        Task { await stats.refreshDue() }
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let heading = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        add(to: menu, "Study", tab: .study, key: "s")
        add(to: menu, "Add a word", tab: .add, key: "n")
        add(to: menu, "Search", tab: .search, key: "f")
        add(to: menu, "Tags", tab: .tags, key: "t")
        add(to: menu, "Progress", tab: .stats, key: "")
        menu.addItem(.separator())
        add(to: menu, "Settings", tab: .settings, key: ",")

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Enka", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var headline: String {
        switch session.state {
        case .connected:
            guard let due = stats.dueNow else { return "Enka \(Bundle.main.shortVersion)" }
            return due == 0 ? "Nothing due" : "\(due) card\(due == 1 ? "" : "s") due"
        case .connecting: return "Connecting…"
        case .failed: return "Server unreachable"
        case .signedOut: return "Not signed in"
        }
    }

    private func add(to menu: NSMenu, _ title: String, tab: NotchViewModel.Tab, key: String) {
        let item = NSMenuItem(title: title, action: #selector(openTab(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = tab.rawValue
        menu.addItem(item)
    }

    @objc private func openTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let tab = NotchViewModel.Tab(rawValue: raw) else { return }
        controller?.open(tab)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
