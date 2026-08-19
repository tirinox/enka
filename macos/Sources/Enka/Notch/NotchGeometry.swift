import AppKit

/// Physical description of the notch (or a synthetic one on Macs without it)
/// plus every derived rect the panel needs, all in screen coordinates.
///
/// Adapted from Cyclop (MIT, github.com/akalikbergenov/cyclop), which worked
/// the numbers out against real hardware; the comments that explain *why* a
/// number is what it is are kept, because the reasons still hold here.
struct NotchGeometry {
    let screen: NSScreen
    /// Size of the physical notch in points.
    let notchSize: CGSize
    /// Horizontal centre of the notch, in global screen coordinates.
    let notchCenterX: CGFloat
    /// True when the display actually has a notch cut into it.
    let isPhysical: Bool

    /// Metrics of the tab rail that do not depend on the notch.
    static let railSpacing: CGFloat = 4
    /// Gap between the rail and the bottom edge of the body.
    static let bodyBottomPadding: CGFloat = 14

    /// Size of the fully expanded panel body. Held constant across every Mac:
    /// letting it follow the header made two people on the very same model see
    /// two different heights, just from different display-scaling settings.
    /// What differs between Macs lives in `railIconHeight` instead, which is
    /// the one thing in the body actually free to give.
    ///
    /// Wider and a little taller than Cyclop's 620×208: a flashcard is read,
    /// not glanced at, and the answer side carries four rating buttons under
    /// the text.
    let expandedSize = CGSize(width: 660, height: 236)

    /// Body for the tabs that show a list — search results and the statistics
    /// breakdown. Same width, so the panel never changes shape sideways; only
    /// the bottom edge moves, and it moves away from the notch.
    static let tallBodyHeight: CGFloat = 396
    var tallExpandedSize: CGSize {
        CGSize(width: expandedSize.width, height: Self.tallBodyHeight)
    }
    /// Tallest body any tab can ask for. The window is cut to this once and
    /// never resized: it is transparent outside the visible panel, and what is
    /// clickable is decided separately by the active rect.
    var maxBodyHeight: CGFloat { max(expandedSize.height, Self.tallBodyHeight) }

    /// What the body has left for content on an ordinary tab, once the header
    /// and the padding beneath are taken out.
    ///
    /// The rail is held to this even on the taller tabs, so the icons stay at
    /// the same height everywhere. Centred in the body instead, they would
    /// slide down by half the difference the moment search opened — putting
    /// the icon just clicked well below the pointer that clicked it.
    var standardContentHeight: CGFloat {
        expandedSize.height - notchSize.height - Self.bodyBottomPadding
    }

    /// Height each rail icon gets. A ceiling, not a constant: the rail has to
    /// fit inside `expandedSize.height − notchSize.height − bodyBottomPadding`
    /// however tall the notch on this particular Mac turns out to be. Rounded
    /// down rather than to nearest: a rail that asks for more than it is given
    /// should visibly yield, not overflow by a fraction that clips it.
    var railIconHeight: CGFloat {
        let icons = CGFloat(NotchViewModel.Tab.allCases.count)
        let available = expandedSize.height - notchSize.height - Self.bodyBottomPadding
        let ceiling = (available - (icons - 1) * Self.railSpacing) / icons
        return min(26, ceiling).rounded(.down)
    }

    /// Slack around the panel so the concave shoulders and shadow are not clipped.
    let windowPadding = NSEdgeInsets(top: 0, left: 40, bottom: 44, right: 40)

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(
                screen: screen,
                notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                notchCenterX: screen.frame.minX + left.width + width / 2,
                isPhysical: true
            )
        }

        // No notch: pretend there is one the size of a typical MacBook cutout so
        // the app still works on external displays and pre-2021 machines.
        //
        // The height has to be the menu bar's own, not `NSStatusBar.thickness`:
        // the two disagree by several points, and the shape is drawn filled
        // black, so anything short of the bar's height reads as a tab stuck onto
        // the menu bar rather than a cutout of it. `visibleFrame` is what the
        // menu bar actually took — measured, not assumed. It collapses to zero
        // when the bar auto-hides, which is what the floor is for.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(
            screen: screen,
            notchSize: CGSize(width: 180, height: max(menuBarHeight, NSStatusBar.system.thickness, 24)),
            notchCenterX: screen.frame.midX,
            isPhysical: false
        )
    }

    /// True when nothing that affects the panel has moved. Screen-parameter
    /// notifications fire for plenty of reasons that leave the notch exactly
    /// where it was, and rebuilding on those would throw away the open state,
    /// the selected tab, and — worse here than in Cyclop — a half-typed card.
    func matches(_ other: NotchGeometry) -> Bool {
        screen.frame == other.screen.frame
            && notchSize == other.notchSize
            && notchCenterX == other.notchCenterX
            && isPhysical == other.isPhysical
    }

    // MARK: - Derived frames

    var windowSize: CGSize {
        CGSize(
            width: expandedSize.width + windowPadding.left + windowPadding.right,
            height: maxBodyHeight + windowPadding.bottom
        )
    }

    /// Panel frame in global screen coordinates, flush with the top of the display.
    var windowFrame: CGRect {
        CGRect(
            x: notchCenterX - windowSize.width / 2,
            y: screen.frame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    /// `CGRect.contains` treats `maxY` as exclusive, and the pointer parks on
    /// exactly `screen.frame.maxY` whenever it is thrown at the top of the
    /// display — which is precisely how one reaches the notch. Every rect that
    /// touches the top edge is grown past it so that position counts as inside.
    private func includingTopEdge(_ rect: CGRect) -> CGRect {
        guard rect.maxY >= screen.frame.maxY else { return rect }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2)
    }

    /// Rect the content occupies inside the window, in screen coordinates.
    func contentScreenRect(for size: CGSize) -> CGRect {
        includingTopEdge(contentRect(for: size).offsetBy(dx: windowFrame.minX, dy: windowFrame.minY))
    }

    /// Rect the content occupies inside the window, in AppKit window coordinates.
    func contentRect(for size: CGSize) -> CGRect {
        CGRect(
            x: (windowSize.width - size.width) / 2,
            y: windowSize.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Depth of the collapsed target, measured down from the top edge.
    ///
    /// A real notch is a hole: the whole of it can be claimed, because there is
    /// nothing underneath to claim it from. A synthetic one is cut out of a
    /// working menu bar — and the middle of the bar is where status items pile
    /// up. Claiming the full bar height there puts the panel in front of icons
    /// the user is aiming at. A strip along the very top edge is reached by
    /// throwing the pointer up — the same gesture as ever — while a pointer
    /// travelling to an icon stays below it.
    var collapsedDepth: CGFloat { isPhysical ? notchSize.height : 8 }

    /// Size of the collapsed target: the notch itself, or the strip above.
    var collapsedSize: CGSize { CGSize(width: notchSize.width, height: collapsedDepth) }

    /// Hover target while collapsed, in global screen coordinates. Slightly
    /// wider than the notch so the panel opens just before the pointer lands.
    var hoverRect: CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - notchSize.width / 2 - 6,
            y: screen.frame.maxY - collapsedDepth - (isPhysical ? 4 : 0),
            width: notchSize.width + 12,
            height: collapsedDepth + (isPhysical ? 4 : 0)
        ))
    }

    /// Band along the top of the display in which pointer sampling runs at
    /// full rate. Deep enough that a pointer heading for the notch is always
    /// noticed before it arrives.
    var warmZone: CGRect {
        includingTopEdge(CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - 260,
            width: screen.frame.width,
            height: 260
        ))
    }

    /// Taken for the body actually on screen, not for the standard one: search
    /// reaches 396 pt down, and a rect cut for 236 would call the pointer
    /// "away" halfway through the list it is resting on.
    func hoverRect(for body: CGSize) -> CGRect {
        includingTopEdge(CGRect(
            x: notchCenterX - body.width / 2 - 12,
            y: screen.frame.maxY - body.height - 12,
            width: body.width + 24,
            height: body.height + 12
        ))
    }
}
