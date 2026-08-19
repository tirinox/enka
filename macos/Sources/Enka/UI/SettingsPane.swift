import ServiceManagement
import SwiftUI

/// Address, secret, and the three switches worth having.
///
/// This is the only tab that works while signed out, and the only one that
/// takes a secret. It asks the two questions separately — is the address right,
/// is the secret right — because conflated they are a guessing game, and the
/// server answers them at two different endpoints anyway.
struct SettingsPane: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var session: Session

    @State private var secret = ""
    @State private var autoPlay = Preferences.autoPlayAudio
    @State private var badge = Preferences.badgeShowsDue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchProblem: String?
    @FocusState private var focus: Focus?

    private enum Focus { case server, secret }

    init(vm: NotchViewModel) {
        self.vm = vm
        self.session = vm.session
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            connection
            Divider().overlay(Theme.hairline)
            options
        }
        .onChange(of: vm.wantsKeyboard) { _, wants in
            if !wants { focus = nil }
        }
    }

    // MARK: - Left: the server

    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabelledField(label: "Server") {
                TextField("", text: $session.serverText, prompt: Text(Preferences.defaultServer).foregroundColor(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.secondary)
                    .focused($focus, equals: .server)
                    .onSubmit { focus = .secret }
            }

            LabelledField(label: "Access secret") {
                // A secure field, and the secret is never shown back: it goes
                // to the keychain and stays there. Somebody re-typing it is
                // somebody who has it written down elsewhere, and the panel
                // hangs over the menu bar in every screen share.
                SecureField("", text: $secret, prompt: Text(session.state.isConnected ? "held in your keychain" : "from `make secret`").foregroundColor(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.secondary)
                    .focused($focus, equals: .secret)
                    .onSubmit { connect() }
            }

            HStack(spacing: 8) {
                Button(session.state.isConnected ? "Reconnect" : "Connect") { connect() }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .disabled(secret.isEmpty && !session.state.isConnected)

                if session.state.isConnected {
                    Button("Sign out") {
                        secret = ""
                        session.signOut()
                    }
                    .buttonStyle(PanelButtonStyle())
                }

                Spacer(minLength: 0)
            }

            status
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        switch session.state {
        case .signedOut:
            note("Run `make secret` in the repository to print it.", tint: Theme.tertiary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
        case let .connected(name):
            VStack(alignment: .leading, spacing: 3) {
                note("Signed in as \(name).", tint: Theme.good, symbol: "checkmark.circle")
                if let version = session.serverVersion {
                    note("Enka \(version)", tint: Theme.tertiary, symbol: nil)
                }
                if let expiry = session.expiresAt {
                    note("Signed in for another \(expiry.relative.replacingOccurrences(of: "in ", with: ""))", tint: Theme.tertiary, symbol: nil)
                }
            }
        case let .failed(message):
            note(message, tint: Theme.again, symbol: "exclamationmark.triangle")
        }
    }

    private func note(_ text: String, tint: Color, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            }
            Text(text)
                .font(.system(size: 11))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
    }

    // MARK: - Right: the switches

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $autoPlay) {
                Text("Play audio automatically")
                    .font(.system(size: 11))
            }
            .onChange(of: autoPlay) { _, value in Preferences.autoPlayAudio = value }

            Toggle(isOn: $badge) {
                Text("Show due count in the menu bar")
                    .font(.system(size: 11))
            }
            .onChange(of: badge) { _, value in
                Preferences.badgeShowsDue = value
                NotificationCenter.default.post(name: .enkaBadgePreferenceChanged, object: nil)
            }

            Toggle(isOn: $launchAtLogin) {
                Text("Open at login")
                    .font(.system(size: 11))
            }
            .onChange(of: launchAtLogin) { _, value in setLaunchAtLogin(value) }

            if let launchProblem {
                Text(launchProblem)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.hard)
                    .lineLimit(2)
            }

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 3) {
                Text("STUDY DEFAULT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                Text(vm.study.mode.blurb)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text("Enka \(Bundle.main.shortVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                Spacer(minLength: 0)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(PanelButtonStyle())
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .foregroundStyle(Theme.secondary)
        .frame(width: 250, alignment: .leading)
    }

    // MARK: - Actions

    private func connect() {
        let typed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            // An empty box while already connected means "the address changed,
            // keep the secret" — which is the common case after moving the
            // server to another host.
            if typed.isEmpty, session.state.isConnected {
                await session.restore()
            } else {
                await session.connect(secret: typed)
            }
            secret = ""
            if session.state.isConnected {
                await vm.stats.refreshDue()
            }
        }
    }

    /// `SMAppService` reports failure by throwing, and the one failure that
    /// actually happens is running from a bundle macOS will not register —
    /// straight out of `swift build`, or from a folder it distrusts. Saying so
    /// beats a switch that flips back with no explanation.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchProblem = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchProblem = "macOS would not set that: \(error.localizedDescription)"
        }
    }
}

/// A labelled box. Three of these on the tab, and each is a label, a rule, and
/// a field — spelled once.
private struct LabelledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
            content
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surface)
                )
        }
    }
}

extension Notification.Name {
    /// The status item owns the badge and the settings tab owns the switch, and
    /// they have no other way to reach each other: the item is built by the app
    /// delegate before any view exists.
    static let enkaBadgePreferenceChanged = Notification.Name("enka.badgePreferenceChanged")
}
