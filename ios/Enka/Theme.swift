import SwiftUI
import UIKit

/// The palette, ported from the web client's `tokens.css` value for value.
///
/// Warm rather than neutral: every grey carries a little red, so a screen full
/// of words reads as paper in low light rather than as a screen, and the clay
/// accent sits on top without shouting. The four rating colours are the same
/// four the web client and the Mac panel use — they are the only place in any
/// of the clients where colour carries meaning rather than emphasis, so a red
/// "Again" here and an orange one there would be a mis-press waiting to happen.
///
/// Both themes are here, unlike the Mac's, which is dark because the notch is.
/// A phone is held in daylight as often as not, and follows the system.
enum Theme {

    // MARK: - Surfaces

    static let bg = c(0xF5F3EE, 0x191817)
    static let bgElevated = c(0xFAF9F5, 0x201F1D)
    static let surface = c(0xFFFFFF, 0x262523)
    static let surfaceHover = c(0xF3F1EB, 0x2E2C29)
    static let surfaceActive = c(0xE9E6DE, 0x363330)

    /// Two hairline weights: one you notice, one you don't.
    static let border = c(0xE2DED4, 0x35322E)
    static let borderStrong = c(0xCBC5B8, 0x46423D)

    // MARK: - Text, loudest to quietest

    static let text = c(0x22201D, 0xF0EEE8)
    static let textMuted = c(0x5F594F, 0xB0AAA0)
    static let textFaint = c(0x8B8478, 0x837D74)
    static let textInverse = c(0xFFFFFF, 0x1A1917)

    // MARK: - Clay, the one accent

    static let accent = c(0xC25F3D, 0xD97757)
    static let accentHover = c(0xAB5133, 0xE08A6D)
    static let accentActive = c(0x954428, 0xC96442)
    static let accentSoft = c(0xC25F3D, 0xD97757, light: 0.10, dark: 0.14)
    static let accentBorder = c(0xC25F3D, 0xD97757, light: 0.28, dark: 0.34)

    // MARK: - Ratings, and the semantics that follow from them

    static let again = c(0xB8443C, 0xCD6A63)
    static let hard = c(0xA9762D, 0xC9954F)
    static let good = c(0x4D7D54, 0x77A37B)
    static let easy = c(0x46709C, 0x6D94BD)

    static let danger = again
    static let dangerSoft = c(0xB8443C, 0xCD6A63, light: 0.10, dark: 0.14)
    static let success = good
    static let warning = hard
    static let info = easy

    static func color(for rating: Rating) -> Color {
        switch rating {
        case .again: return again
        case .hard: return hard
        case .good: return good
        case .easy: return easy
        }
    }

    // MARK: - Shape and time

    static let radiusSmall: CGFloat = 6
    static let radius: CGFloat = 10
    static let radiusLarge: CGFloat = 14
    static let radiusExtraLarge: CGFloat = 20

    /// The web client's `--ease`, which is the curve everything in Enka moves
    /// on: quick to leave, slow to settle.
    static func ease(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }

    static let fast = ease(0.12)
    static let normal = ease(0.22)

    // MARK: - Building

    /// One token, both themes, resolved by the system rather than by a
    /// `@Environment` read — so a colour works anywhere, including inside the
    /// shape and shadow modifiers that never see the environment.
    private static func c(
        _ light: UInt32, _ dark: UInt32, light lightAlpha: CGFloat = 1, dark darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// The one prominent button: clay, full width, and large enough to hit without
/// looking. Used for the action a screen exists to perform, and nothing else.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Theme.textInverse : Theme.textFaint)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(isEnabled
                          ? (configuration.isPressed ? Theme.accentActive : Theme.accent)
                          : Theme.surfaceActive)
            )
            .animation(Theme.fast, value: configuration.isPressed)
    }
}

/// A quiet button on a surface — the second thing on a screen, never the first.
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.surfaceActive : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .animation(Theme.fast, value: configuration.isPressed)
    }
}
