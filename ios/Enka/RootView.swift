import SwiftUI

/// One of three things, decided by the session and nothing else.
struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        Group {
            switch session.state {
            case .connected:
                StudyView()
            case .connecting:
                // `restore()` runs before the first frame, so this is what a
                // cold launch with a token in the keychain actually shows.
                VStack(spacing: 16) {
                    ProgressView().tint(Theme.accent)
                    Text("Connecting…")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            case .signedOut, .failed:
                // `failed` lands here too: a token that stopped working and no
                // token at all need the same screen, and SignInView says which
                // of the two it is.
                SignInView()
            }
        }
        .animation(Theme.normal, value: session.state)
    }
}
