import AppKit

/// Content view of the panel. Everything outside `activeRect` is click-through,
/// so the window can stay at its full expanded size while the panel is collapsed.
///
/// Adapted from Cyclop (MIT, github.com/akalikbergenov/cyclop). The drag
/// destination is gone — Enka has nothing to drop onto it — and what is left is
/// the click-through and cursor bookkeeping, which every notch panel needs.
final class NotchRootView: NSView {
    /// Interactive area, in window coordinates.
    var activeRect: CGRect = .zero {
        didSet {
            guard activeRect != oldValue else { return }
            refreshCursorArea()
        }
    }

    private var cursorArea: NSTrackingArea?

    /// The app never becomes active, so without this the first click on the
    /// panel would be spent activating instead of hitting the control.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard activeRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshCursorArea()
    }

    /// The cursor shape comes from the topmost window claiming a region under
    /// the pointer. Claiming nothing does not mean "leave the cursor alone", it
    /// means the panel is invisible to that lookup and the window underneath
    /// gets to decide — an I-beam over a text editor, say. So claim exactly the
    /// part of the panel that takes events and pin it to the arrow.
    ///
    /// A cursor rect would not do: AppKit disables those for non-key windows,
    /// and this panel is usually not key. `.activeAlways` keeps the tracking
    /// area live regardless of that and of the app being inactive.
    private func refreshCursorArea() {
        if let cursorArea {
            removeTrackingArea(cursorArea)
            self.cursorArea = nil
        }
        guard !activeRect.isEmpty else { return }
        let area = NSTrackingArea(
            rect: activeRect,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        cursorArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// The pointer can already be inside a freshly installed area — entering is
    /// then the first notification we get, and no cursor update precedes it.
    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
