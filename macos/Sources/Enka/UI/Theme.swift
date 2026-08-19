import SwiftUI

/// The panel's palette and its timings.
///
/// The panel body is black because the notch is black on every Mac that has
/// one, and a body that is any other colour reads as a rectangle stuck under
/// the cutout rather than as the cutout growing. Everything above that black is
/// therefore an overlay — but a *warm* one: the whites carry a little red, the
/// same way the web client's greys do, so the panel reads as paper in low light
/// rather than as a screen. The clay accent is the web client's `--accent`
/// unchanged, because the two clients should look like one product.
enum Theme {
    // MARK: - Timings

    static let openAnimation = Animation.spring(response: 0.27, dampingFraction: 0.82)
    static let contentAnimation = Animation.easeOut(duration: 0.16)
    /// Pane switching: the outgoing pane leaves faster than the incoming one
    /// arrives, so the two are never both half-visible for long.
    static let paneAnimation = Animation.easeOut(duration: 0.18)
    static let paneIn = Animation.easeOut(duration: 0.20).delay(0.04)
    static let paneOut = Animation.easeIn(duration: 0.12)
    /// Revealing an answer. Slower than a pane swap and deliberately so: it is
    /// the one moment in the app that is worth watching, and a card that snaps
    /// open gives the eye nowhere to land.
    static let revealAnimation = Animation.spring(response: 0.34, dampingFraction: 0.86)

    // MARK: - Silhouette

    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 22

    // MARK: - Ink
    //
    // Warm rather than neutral. `Color.white` at 55% over black is grey; these
    // are the same idea with the web client's `--text-muted` hue kept, which is
    // what stops the panel looking like a different application.

    static let ink = Color(red: 0.94, green: 0.93, blue: 0.91)
    static let secondary = Color(red: 0.94, green: 0.93, blue: 0.91).opacity(0.62)
    static let tertiary = Color(red: 0.94, green: 0.93, blue: 0.91).opacity(0.34)

    static let surface = Color.white.opacity(0.07)
    static let surfaceHover = Color.white.opacity(0.13)
    static let hairline = Color.white.opacity(0.10)

    // MARK: - Clay

    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341)      // #D97757
    static let accentSoft = accent.opacity(0.16)
    static let accentBorder = accent.opacity(0.34)

    // MARK: - Ratings
    //
    // The web client's four, unchanged. They are the only place in either
    // client where colour carries meaning rather than emphasis, so they have to
    // agree — a red "Again" here and an orange one there is a mis-press.

    static let again = Color(red: 0.804, green: 0.416, blue: 0.388)   // #CD6A63
    static let hard = Color(red: 0.788, green: 0.584, blue: 0.310)    // #C9954F
    static let good = Color(red: 0.467, green: 0.639, blue: 0.482)    // #77A37B
    static let easy = Color(red: 0.427, green: 0.580, blue: 0.741)    // #6D94BD

    static func color(for rating: Rating) -> Color {
        switch rating {
        case .again: return again
        case .hard: return hard
        case .good: return good
        case .easy: return easy
        }
    }

    /// The heatmap ramp, coolest to warmest — the web client's, so a streak
    /// looks the same in both places.
    static let heat: [Color] = [
        Color(red: 0.137, green: 0.133, blue: 0.125),
        Color(red: 0.290, green: 0.227, blue: 0.188),
        Color(red: 0.478, green: 0.322, blue: 0.251),
        Color(red: 0.690, green: 0.416, blue: 0.298),
        Color(red: 0.878, green: 0.541, blue: 0.388),
    ]
}

/// A flat, focus-free control, used for anything in the panel that is pressed
/// rather than typed into. SwiftUI's focus ring has nowhere to sit on a
/// borderless panel, and the system's own button chrome assumes a window with a
/// title bar above it.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominent ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Theme.surfaceHover : Theme.surface)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A keyboard hint, drawn as a key.
///
/// Every shortcut in the panel is shown next to the thing it does, because the
/// panel has no menu bar to discover them from and no window to put a help
/// button on. The cap is the whole documentation.
struct KeyCap: View {
    let label: String
    var tint: Color = Theme.tertiary

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .frame(minWidth: 14)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

/// Raises a flag and lowers it a moment later — the panel's only way of saying
/// "that worked", since whatever was done has usually gone somewhere the panel
/// cannot see.
@MainActor
func flash(_ flag: Binding<Bool>) {
    flag.wrappedValue = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
        flag.wrappedValue = false
    }
}

extension Date {
    /// "in 3 days", "2 hours ago" — the one date phrasing the panel uses, and
    /// the system's own, so it follows the user's language without a table.
    var relative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
