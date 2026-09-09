import SwiftUI

/// The address, the secret, and the handful of switches worth having.
///
/// It asks the two connection questions separately — is the address right, is
/// the secret right — because conflated they are a guessing game, and the
/// server answers them at two different endpoints anyway. Everything else here
/// is a preference the study screen reads on its way to a card.
struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var study: StudySession
    @EnvironmentObject private var stats: StatsStore

    @State private var secret = ""
    @State private var autoPlay = Preferences.autoPlayAudio
    @State private var nativeLanguage = ""
    @State private var nativeLanguageProblem: String?
    @State private var isSigningOut = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case server, secret, nativeLanguage }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                studySection
                aiSection
                tagsSection
                accountSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.accent)
        .onAppear { nativeLanguage = session.nativeLanguage ?? "" }
        .onChange(of: session.nativeLanguage) { _, value in nativeLanguage = value ?? "" }
        .confirmationDialog(
            "Sign out of Enka?",
            isPresented: $isSigningOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                secret = ""
                session.signOut()
            }
            Button("Stay signed in", role: .cancel) {}
        } message: {
            Text("The secret leaves the keychain, and this phone will ask for it again.")
        }
    }

    // MARK: - The server

    private var serverSection: some View {
        Section {
            TextField(Preferences.defaultServer, text: $session.serverText)
                .font(.callout.monospaced())
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .server)
                .onSubmit { focus = .secret }

            // Never shown back: it goes to the keychain and stays there. An
            // empty box while already connected means "the address changed,
            // keep the secret" — which is the common case after moving the
            // server to another host.
            SecureField(
                session.state.isConnected ? "held in your keychain" : "from `make secret`",
                text: $secret
            )
            .font(.callout.monospaced())
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .focused($focus, equals: .secret)
            .onSubmit(connect)

            Button(action: connect) {
                HStack {
                    Text(session.state.isConnected ? "Reconnect" : "Connect")
                        .fontWeight(.medium)
                    Spacer()
                    if session.state == .connecting { ProgressView() }
                }
            }
            .disabled(secret.isEmpty && !session.state.isConnected)
        } header: {
            Text("Server")
        } footer: {
            status
        }
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder private var status: some View {
        switch session.state {
        case .signedOut:
            Text("Run `make secret` in the repository to print it.")
        case .connecting:
            Text("Connecting…")
        case let .connected(name):
            VStack(alignment: .leading, spacing: 3) {
                Label("Signed in as \(name).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                if let version = session.serverVersion {
                    Text("Enka \(version)")
                }
                if let expiry = session.expiresAt {
                    Text("Signed in for another \(expiry.relative.replacingOccurrences(of: "in ", with: ""))")
                }
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
        }
    }

    private func connect() {
        let typed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        focus = nil
        Task {
            if typed.isEmpty, session.state.isConnected {
                await session.restore()
            } else {
                await session.connect(secret: typed)
            }
            secret = ""
            if session.state.isConnected { await stats.refreshDue() }
        }
    }

    // MARK: - Study

    /// The same two settings the study screen's own menu carries, because this
    /// is where somebody goes looking for them and a menu behind an ellipsis is
    /// not a place anybody looks first. Both write through `Preferences`, so
    /// they survive the app being closed.
    private var studySection: some View {
        Section {
            Picker("Which cards", selection: $study.mode) {
                ForEach(StudyMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Asked", selection: $study.direction) {
                ForEach(StudyDirection.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $autoPlay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play audio automatically")
                    Text("Whichever side has just become readable.")
                        .font(.caption)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .tint(Theme.accent)
            .onChange(of: autoPlay) { _, value in Preferences.autoPlayAudio = value }
        } header: {
            Text("Study")
        } footer: {
            Text(study.mode.blurb)
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - AI

    private var aiSection: some View {
        Section {
            HStack {
                TextField("e.g. ru", text: $nativeLanguage)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .nativeLanguage)
                    .onSubmit(saveNativeLanguage)
                if nativeLanguage.trimmingCharacters(in: .whitespaces) != (session.nativeLanguage ?? "") {
                    Button("Save", action: saveNativeLanguage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        } header: {
            Text("Native language")
        } footer: {
            if let problem = nativeLanguageProblem {
                NoticeLine(text: problem)
            } else {
                Text("What Translate translates into, on the Add screen and in the card editor.")
            }
        }
        .listRowBackground(Theme.surface)
    }

    /// Saved on submit, not on every keystroke — a language code is typed once
    /// and left alone, unlike the toggles above it.
    private func saveNativeLanguage() {
        let trimmed = nativeLanguage.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != (session.nativeLanguage ?? "") else { return }
        nativeLanguageProblem = nil
        focus = nil
        Task {
            do {
                try await session.setNativeLanguage(trimmed)
            } catch let error as APIError {
                nativeLanguageProblem = error.message
            } catch {
                nativeLanguageProblem = error.localizedDescription
            }
        }
    }

    // MARK: - The rest

    private var tagsSection: some View {
        Section {
            NavigationLink {
                TagsView()
            } label: {
                Label("Tags", systemImage: "tag")
            }
        }
        .listRowBackground(Theme.surface)
    }

    private var accountSection: some View {
        Section {
            Button(role: .destructive) {
                isSigningOut = true
            } label: {
                Text("Sign out").frame(maxWidth: .infinity)
            }
        } footer: {
            HStack {
                Spacer()
                Text("Enka \(Bundle.main.shortVersion)")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .padding(.top, 8)
        }
        .listRowBackground(Theme.surface)
    }
}

extension Bundle {
    /// The version out of `Info.plist`, for the line at the bottom of the
    /// settings — the cheapest possible answer to "which build is this?".
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
