import SwiftUI
import UIKit

/// The address and the secret, once.
///
/// Enka has no accounts: the server holds one secret, and a client that sends
/// it gets a thirty-day token back. So this screen is asked for once and then
/// ideally never again — which is the argument for making the two fields as
/// hard to get wrong as possible rather than as small as possible.
///
/// The two values almost always arrive together, because they are useless
/// apart. Everything here is arranged around that: paste whatever carries them
/// and `PastedCredentials` decides which is which.
struct SignInView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.scenePhase) private var scenePhase

    @State private var secret = ""
    @State private var secretIsVisible = false
    @State private var clipboardHasText = false
    @State private var note: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case server, secret }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                fields
                pasteButton
                message
                connectButton
                hint
            }
            .padding(24)
            .frame(maxWidth: 480)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .tint(Theme.accent)
        .onAppear(perform: refreshClipboard)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshClipboard() }
        }
        // The same call on both fields, because a paste can land in either one
        // and neither is the "right" place to put a line holding both.
        .onChange(of: secret) { _, text in split(text) }
        .onChange(of: session.serverText) { _, text in split(text) }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enka")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text("Point the app at your server and give it the secret `make secret` printed.")
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.top, 28)
        .padding(.bottom, 4)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            LabeledField(label: "Server") {
                TextField(Preferences.defaultServer, text: $session.serverText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .server)
                    .onSubmit { focus = .secret }
            }
            Divider().overlay(Theme.border).padding(.leading, 16)
            LabeledField(label: "Secret") {
                HStack(spacing: 10) {
                    Group {
                        if secretIsVisible {
                            TextField("", text: $secret)
                        } else {
                            SecureField("", text: $secret)
                        }
                    }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focus, equals: .secret)
                    .onSubmit(connect)

                    // Thirty-two random characters typed on a phone keyboard is
                    // a typo waiting to happen, and the error it produces —
                    // "wrong secret" — is indistinguishable from having the
                    // wrong one. This is for checking a paste landed, not for
                    // reading a secret out loud.
                    if !secret.isEmpty {
                        Button {
                            secretIsVisible.toggle()
                        } label: {
                            Image(systemName: secretIsVisible ? "eye.slash" : "eye")
                                .foregroundStyle(Theme.textFaint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    /// Shown only when there is something to paste. `hasStrings` answers that
    /// without reading the clipboard, which is what keeps the system's "Enka
    /// pasted from…" banner tied to the button actually being pressed.
    @ViewBuilder private var pasteButton: some View {
        if clipboardHasText {
            Button(action: pasteFromClipboard) {
                Label("Paste from clipboard", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    @ViewBuilder private var message: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.danger)
        } else if let note {
            Label(note, systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.success)
        }
    }

    private var connectButton: some View {
        Button(action: connect) {
            if session.state == .connecting {
                ProgressView().tint(Theme.textInverse)
            } else {
                Text("Connect")
            }
        }
        .buttonStyle(AccentButtonStyle())
        .disabled(secret.isEmpty || session.serverText.isEmpty || session.state == .connecting)
    }

    /// The split is invisible until it happens, so it is worth one line of
    /// saying so — otherwise the only way to find it is to have done it.
    private var hint: some View {
        Text("The address and the secret can be pasted together, in one go.")
            .font(.footnote)
            .foregroundStyle(Theme.textFaint)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: - Actions

    private func connect() {
        focus = nil
        Task { await session.connect(secret: secret) }
    }

    private func refreshClipboard() {
        clipboardHasText = UIPasteboard.general.hasStrings
    }

    /// The button reads the clipboard and takes whatever it finds — one value
    /// or two. Unlike the automatic split, a press is unambiguous: nothing
    /// here can be mistaken for someone typing.
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string else {
            clipboardHasText = false
            return
        }
        let parsed = PastedCredentials.parse(text)
        if let server = parsed.server { session.serverText = server }
        if let found = parsed.secret { secret = found }

        switch (parsed.server, parsed.secret) {
        case (.some, .some): announce("Address and secret filled in.")
        case (.some, .none): announce("Address filled in.")
        case (.none, .some): announce("Secret filled in.")
        case (.none, .none): announce("Nothing on the clipboard that looks like either.")
        }
    }

    /// Runs on every keystroke in both fields and almost always does nothing:
    /// `apply` writes only when it found *both* values, and typing produces at
    /// most one.
    private func split(_ text: String) {
        guard PastedCredentials.apply(text, server: &session.serverText, secret: &secret) else {
            return
        }
        announce("Address and secret split out.")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func announce(_ message: String) {
        withAnimation(Theme.normal) { note = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(Theme.normal) { note = nil }
        }
    }

    private var failure: String? {
        if case .failed(let message) = session.state { return message }
        return nil
    }
}

/// A label above a control, at the row height the rest of iOS uses for forms.
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textFaint)
            content
                .font(.body)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
