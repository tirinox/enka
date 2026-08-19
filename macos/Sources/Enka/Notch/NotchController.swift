import AppKit
import Combine
import SwiftUI

/// Owns the panel and everything about when it is open.
///
/// The structure is Cyclop's (MIT, github.com/akalikbergenov/cyclop) and so are
/// most of the comments, because the problems are the same ones: a window above
/// the menu bar that must be click-through everywhere it is not visible, hover
/// tracking that has to survive a display change, and a close that has to
/// happen in two passes or SwiftUI leaves the panel painted open.
///
/// What is Enka's own is the shared state. `Session`, `AudioPlayback` and
/// `StatsStore` are built once by the app delegate and handed in, so that
/// rebuilding the panel — which a second monitor being plugged in does — never
/// signs the user out or drops the due count.
@MainActor
final class NotchController {
    private var panel: NotchPanel?
    private var rootView: NotchRootView?
    private var viewModel: NotchViewModel?
    private let pointer = PointerWatcher()
    private var closeActiveRectWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    /// Monotonic stamp for the deferred half of closing: any newer open or
    /// close outdates the one still in flight.
    private var openGeneration = 0

    private let session: Session
    private let audio: AudioPlayback
    private let stats: StatsStore

    init(session: Session, audio: AudioPlayback, stats: StatsStore) {
        self.session = session
        self.audio = audio
        self.stats = stats
    }

    func install() {
        build()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }
        // A dark display has no hover to watch, so the one timer that never
        // otherwise stops — the pointer sampler — stops with it. The panel
        // closes too, so waking always starts from the same, folded state.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setOpen(false)
                self.pointer.setInside(false)
                self.pointer.stop()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointer.start() }
        }
    }

    /// The panel belongs to the desktop it was opened on. ⌘-Tab to another one
    /// leaves the pointer wherever it happened to be — which is not a decision
    /// to keep the panel expanded over a screen the user has just arrived at.
    private func activeSpaceChanged() {
        guard viewModel?.isOpen == true else { return }
        setOpen(false)
        pointer.setInside(false)
    }

    private func screenParametersChanged() {
        let fresh = NotchGeometry.current()
        guard let current = viewModel?.geometry, current.matches(fresh) else {
            rebuild()
            return
        }
        // Same display, same notch: keep the panel and everything on it.
        panel?.setFrame(fresh.windowFrame, display: false)
    }

    func teardown() {
        pointer.stop()
        viewModel?.stop()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
    }

    func toggle() {
        guard let viewModel else { return }
        setOpen(!viewModel.isOpen)
        pointer.setInside(viewModel.isOpen)
    }

    /// Opens the panel straight onto one tab. What the status menu's shortcuts
    /// do, and what a click on the due badge does.
    func open(_ tab: NotchViewModel.Tab) {
        guard let viewModel else { return }
        viewModel.select(tab)
        setOpen(true)
        pointer.setInside(true)
    }

    // MARK: - Construction

    private func rebuild() {
        let previousTab = viewModel?.tab
        pointer.stop()
        viewModel?.stop()
        closeActiveRectWork?.cancel()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        rootView = nil
        viewModel = nil
        build()
        if let previousTab { viewModel?.tab = previousTab }
    }

    private func build() {
        let geometry = NotchGeometry.current()
        let vm = NotchViewModel(geometry: geometry, session: session, audio: audio, stats: stats)
        viewModel = vm

        let panel = NotchPanel(contentRect: geometry.windowFrame)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: geometry.windowSize))
        root.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: NotchContentView(vm: vm))
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        root.addSubview(hosting)

        // Clicking away drops the keyboard but leaves the tab where it was, so
        // a click back into the panel has to be able to ask for it again. It is
        // also how the study tab earns the keyboard at all — see
        // `NotchViewModel.Tab.needsKeyboard`.
        panel.onPress = { [weak self] in
            self?.viewModel?.pressedInside()
        }
        panel.onKeyDown = { [weak self] event in
            self?.handle(event) ?? false
        }

        panel.contentView = root
        panel.ignoresMouseEvents = true
        panel.setFrame(geometry.windowFrame, display: false)
        panel.orderFrontRegardless()

        self.panel = panel
        self.rootView = root

        applyActiveRect(open: false)

        pointer.openRect = geometry.hoverRect
        pointer.warmZone = geometry.warmZone
        // Cut for the tab that will be showing, not for the standard body: a
        // rebuild restores the previous tab, and search reaches much further
        // down than study does.
        pointer.closeRect = geometry.hoverRect(for: vm.openBodySize)
        // A real notch is a hole: nothing is under it, so opening the moment
        // the pointer arrives costs nothing. A synthetic one sits on a working
        // menu bar, and a pointer crossing the middle of it is usually on its
        // way somewhere else — unfolding the panel over what it was reaching
        // for is the whole complaint. Staying put is what asks for the panel.
        pointer.openDelay = geometry.isPhysical ? 0.05 : 0.3
        pointer.isPanelOpen = { [weak vm] in vm?.isOpen ?? false }
        pointer.onChange = { [weak self] inside in
            self?.setOpen(inside)
        }
        // Everything outside the visible panel must reach the app underneath:
        // a `nil` from hitTest only discards the event, it does not forward it.
        pointer.onInteractiveChange = { [weak self] interactive in
            self?.panel?.ignoresMouseEvents = !interactive
        }
        pointer.start()

        // Switching tabs can change how far down the panel reaches, and both
        // the clickable region and the region the pointer counts as "on the
        // panel" are cut from that. Left alone, search would open to its full
        // height with only its top 236 pt alive.
        vm.$tab
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let vm = self.viewModel, vm.isOpen else { return }
                    // A pass later: `openBodySize` reads `tab`, and this fires
                    // while the property is still being set.
                    DispatchQueue.main.async { self.refreshOpenRects() }
                }
            }
            .store(in: &cancellables)

        // Driven by the deliberate request, not by which tab is showing: a
        // hover can land on a typing tab now, and that alone must not take the
        // keyboard away from the window underneath.
        vm.$wantsKeyboard
            .removeDuplicates()
            .sink { [weak self] wants in
                MainActor.assumeIsolated { self?.setKeyboard(wants) }
            }
            .store(in: &cancellables)

        // Clicking into another app drops the keyboard: there is no
        // click-outside to catch, but losing key status says the same. The tab
        // stays as it was — only the claim on the keyboard is dropped.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.viewModel?.wantsKeyboard = false }
            }
            .store(in: &cancellables)

        vm.start()

        // A rebuilt panel starts closed. If the pointer is already sitting on
        // it, reopen at once instead of waiting for a trip back to the notch.
        if geometry.hoverRect(for: vm.openBodySize).contains(NSEvent.mouseLocation) {
            pointer.setInside(true)
            setOpen(true)
        }
    }

    // MARK: - Keyboard
    //
    // Matched on key codes, not characters. Enka is a language app: its user is
    // expected to be on a foreign layout while studying, and `1`–`4` survive
    // that where `u` does not.

    private enum Code {
        static let space: UInt16 = 49
        static let one: UInt16 = 18
        static let two: UInt16 = 19
        static let three: UInt16 = 20
        static let four: UInt16 = 21
        static let u: UInt16 = 32
        static let r: UInt16 = 15
        static let escape: UInt16 = 53
    }

    /// Returns true when the press has been dealt with.
    ///
    /// Only the study tab is served. Every other tab has a field in it, and a
    /// digit typed into the add tab must stay a digit — silently turning it
    /// into a rating would be the worst kind of shortcut.
    private func handle(_ event: NSEvent) -> Bool {
        guard let vm = viewModel else { return false }
        // Escape empties the field in front of you, and folds the panel when
        // there is nothing to empty. Two meanings for one key, but they are the
        // same meaning applied to the nearest thing — and the alternative is a
        // panel that vanishes when you meant to clear a typo.
        //
        // Handled here rather than in the panes because this runs before the
        // press is delivered: a `.onKeyPress(.escape)` inside a field would
        // never see the key at all.
        if event.keyCode == Code.escape {
            if vm.tab == .add, !vm.capture.term.isEmpty || !vm.capture.definition.isEmpty {
                vm.capture.clear()
                return true
            }
            if vm.tab == .search, !vm.search.query.isEmpty {
                vm.search.clear()
                return true
            }
            vm.wantsKeyboard = false
            setOpen(false)
            pointer.setInside(false)
            return true
        }
        guard vm.tab == .study,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }

        switch event.keyCode {
        case Code.space:
            vm.study.reveal()
        case Code.one:
            vm.study.answer(.again)
        case Code.two:
            vm.study.answer(.hard)
        case Code.three:
            vm.study.answer(.good)
        case Code.four:
            vm.study.answer(.easy)
        case Code.u:
            vm.study.undo()
        case Code.r:
            guard let card = vm.study.currentCard else { return true }
            let side = vm.study.visibleSide(of: card, revealed: vm.study.isRevealed)
            audio.playAll(card.card.clips(for: side), using: session)
        default:
            return false
        }
        return true
    }

    // MARK: - Open / close

    /// Hands the keyboard to the panel, or gives it back.
    private func setKeyboard(_ wants: Bool) {
        if wants {
            setOpen(true)
            pointer.setInside(true)
        }
        panel?.acceptsKeyboard = wants
        // What was typed stays: clicking away to look something up should not
        // be the same as throwing the word out.
        if !wants { scheduleCollapseIfPointerAway() }
    }

    /// The pointer decides. A half-typed card does not hold the panel open: it
    /// is opened by hovering, and anything that survives the pointer leaving
    /// has to be dismissed some other way, which is a second rule to learn for
    /// a panel that has exactly one. What was typed is kept, so coming back
    /// finds it where it was left.
    private func setOpen(_ open: Bool) {
        guard let vm = viewModel, vm.isOpen != open else { return }
        openGeneration += 1
        closeActiveRectWork?.cancel()

        if open {
            // Grow the interactive area first so the pointer never falls
            // through a region the animation has not covered yet.
            applyActiveRect(open: true)
            withAnimation(Theme.openAnimation) { vm.isOpen = true }
            vm.study.setActive(vm.tab == .study)
            if vm.tab == .stats { vm.stats.refresh() }
        } else {
            // The keyboard goes first and the fold goes second — one run-loop
            // pass apart, never together. Dropped in the same pass, resigning
            // the field's first responder and structurally removing that field
            // land in one transaction, and SwiftUI applies the state but loses
            // the repaint: the panel stands on screen fully expanded with
            // `isOpen` already false, wedged until the next hover repaints it.
            vm.wantsKeyboard = false
            let generation = openGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openGeneration == generation else { return }
                self.collapse()
            }
        }
    }

    /// The visual half of closing, one pass after the keyboard was let go.
    private func collapse() {
        guard let vm = viewModel, vm.isOpen else { return }
        withAnimation(Theme.openAnimation) { vm.isOpen = false }
        vm.study.setActive(false)
        audio.stop()
        // Shrink only once the panel has finished collapsing. Doing it while it
        // is still visibly there would leave a window in which clicks land on
        // whatever is behind the panel.
        let work = DispatchWorkItem { [weak self] in self?.applyActiveRect(open: false) }
        closeActiveRectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func scheduleCollapseIfPointerAway() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            // Resync either way. A pointer that is still on the panel has to be
            // recorded as inside, or hover tracking stays convinced it left and
            // the panel hangs open until the notch is touched again.
            let away = !vm.geometry.hoverRect(for: vm.openBodySize).contains(NSEvent.mouseLocation)
            self.pointer.setInside(!away)
            if away { self.setOpen(false) }
        }
    }

    /// Re-cuts both rects for the body currently on screen.
    private func refreshOpenRects() {
        guard let vm = viewModel, vm.isOpen else { return }
        applyActiveRect(open: true)
        pointer.closeRect = vm.geometry.hoverRect(for: vm.openBodySize)
    }

    private func applyActiveRect(open: Bool) {
        guard let vm = viewModel, let rootView else { return }
        // Collapsed, the panel claims only its target strip — on a synthetic
        // notch that is deliberately shallower than the menu bar, so clicks on
        // status items underneath reach them instead of a panel nobody can see.
        let size = open ? vm.openBodySize : vm.geometry.collapsedSize
        var rect = vm.geometry.contentRect(for: size)
        if open {
            // Slack so the concave shoulders stay grabbable. Never while
            // collapsed: that would swallow clicks on menu bar items next to
            // the notch.
            rect = rect.insetBy(dx: -Theme.openTopRadius, dy: 0)
        }
        rootView.activeRect = rect
        pointer.interactiveRect = vm.geometry
            .contentScreenRect(for: size)
            .insetBy(dx: open ? -Theme.openTopRadius : 0, dy: 0)
    }
}
