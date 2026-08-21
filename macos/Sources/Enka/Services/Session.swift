import Combine
import Foundation

/// Who the panel is talking to, and whether it is allowed to.
///
/// Enka's server has no accounts: it holds one secret, and a client that sends
/// it once gets a JWT good for thirty days back. So "signing in" is a single
/// exchange, and the interesting part is everything after it — a token that
/// expires while nobody is looking, a laptop that woke up somewhere without the
/// server on it, a `docker compose down` in another window.
///
/// Every other store goes through `run`, which is what makes those cases
/// invisible: a call that comes back 401 is retried once against a freshly
/// minted token, and only a second failure is allowed to reach a pane.
@MainActor
final class Session: ObservableObject {
    enum State: Equatable {
        /// No secret held. The settings tab is the only useful thing to look at.
        case signedOut
        case connecting
        case connected(name: String)
        /// A secret is held and it did not work — or the server is not there.
        /// Kept apart from `signedOut` because the remedy is different, and the
        /// panel says which.
        case failed(message: String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .signedOut
    /// The address as it stands in the settings field. Committed to
    /// `Preferences` only when it is actually used to connect, so a half-typed
    /// hostname never becomes the saved one.
    @Published var serverText: String = Preferences.serverURL
    /// Version string from `/health`, shown in settings — the cheapest possible
    /// proof that the thing answering is the API and not a proxy error page.
    @Published private(set) var serverVersion: String?
    /// Nil until set via the settings tab, or prompted for the first time a
    /// translation is requested. Used by the AI translation feature.
    @Published private(set) var nativeLanguage: String?

    let client: APIClient

    private var secret: String? {
        didSet { Keychain.write(secret, to: Keychain.secretAccount) }
    }
    private var token: String? {
        didSet { Keychain.write(token, to: Keychain.tokenAccount) }
    }
    private var tokenExpiry: Date? {
        didSet { Preferences.tokenExpiry = tokenExpiry }
    }
    /// Guards against two panes discovering the same expired token at once and
    /// each minting a replacement.
    private var renewal: Task<Void, Error>?

    init() {
        client = APIClient(root: Preferences.serverRoot)
    }

    // MARK: - Lifecycle

    /// Picks up where the last run left off, without asking for anything.
    ///
    /// The token is used as-is when it still has a day left on it: a launch
    /// should not spend a round trip re-proving something the keychain already
    /// knows. Anything shorter is renewed at once, because a token that expires
    /// mid-session expires in the middle of somebody answering a card.
    func restore() async {
        secret = Keychain.read(Keychain.secretAccount)
        token = Keychain.read(Keychain.tokenAccount)
        tokenExpiry = Preferences.tokenExpiry
        guard secret != nil || token != nil else {
            state = .signedOut
            return
        }
        await client.setToken(token)
        state = .connecting
        do {
            try await ensureToken()
            let me = try await client.me()
            state = .connected(name: me.name)
            tokenExpiry = me.tokenExpiresAt
            nativeLanguage = me.nativeLanguage
        } catch let error as APIError {
            state = .failed(message: error.message)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    /// The settings tab's one action: take an address and a secret, and either
    /// be connected or say why not.
    func connect(secret newSecret: String) async {
        guard let root = Preferences.url(from: serverText) else {
            state = .failed(message: "That does not look like an address.")
            return
        }
        Preferences.serverURL = serverText
        await client.setRoot(root)
        state = .connecting
        serverVersion = nil

        do {
            // Asked first, and unauthenticated, so that a wrong address and a
            // wrong secret give different answers. Told apart, the two are one
            // fix each; conflated, they are a guessing game.
            let health = try await client.health()
            serverVersion = health.version

            let response = try await client.token(secret: newSecret)
            secret = newSecret
            token = response.accessToken
            tokenExpiry = response.expiresAt
            await client.setToken(response.accessToken)

            let me = try await client.me()
            state = .connected(name: me.name)
            nativeLanguage = me.nativeLanguage
        } catch let error as APIError {
            state = .failed(message: error.isOffline ? "No server at \(serverText)." : error.message)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func signOut() {
        renewal?.cancel()
        renewal = nil
        secret = nil
        token = nil
        tokenExpiry = nil
        serverVersion = nil
        nativeLanguage = nil
        state = .signedOut
        Task { await client.setToken(nil) }
    }

    /// Currently the only editable field on the owner. Used by the AI
    /// translation feature — the settings tab, and search's own translate
    /// action when nothing is set yet, both funnel through here.
    func setNativeLanguage(_ language: String) async throws {
        let me = try await run { try await $0.updateMe(nativeLanguage: language) }
        nativeLanguage = me.nativeLanguage
    }

    /// How long the current token has left, for the line in settings. Nil when
    /// there is nothing signed in.
    var expiresAt: Date? { state.isConnected ? tokenExpiry : nil }

    // MARK: - Calling

    /// Runs one API call with the session's guarantees around it.
    ///
    /// Two of them. The token is refreshed before the call if it is about to
    /// expire, and a 401 that gets through anyway is retried once against a new
    /// one — the server's `ENKA_JWT_SECRET` changing under a running app looks
    /// exactly like that, and it is a `docker compose up` away.
    ///
    /// Failures are returned, not swallowed: each pane decides what an error
    /// means for what it is showing, and a study pane that goes blank on a
    /// hiccup is worse than one that says "again?".
    func run<T>(_ body: @Sendable (APIClient) async throws -> T) async throws -> T {
        try await ensureToken()
        do {
            return try await body(client)
        } catch let error as APIError where error.isAuthFailure {
            // Force a mint, not a check: whatever the expiry said, the server
            // has just disagreed with it.
            tokenExpiry = nil
            try await ensureToken()
            let result = try await body(client)
            // The retry working is the only proof that the session is healthy
            // again — a pane may have been showing a failure until now.
            if case .failed = state, let name = try? await client.me().name {
                state = .connected(name: name)
            }
            return result
        }
    }

    /// Mints a token if there is none, or if the one held is inside its last
    /// day. Concurrent callers share the single in-flight mint.
    private func ensureToken() async throws {
        if let expiry = tokenExpiry, expiry.timeIntervalSinceNow > 86_400, token != nil { return }
        if token != nil, tokenExpiry == nil, secret == nil { return } // nothing to renew with

        if let renewal {
            try await renewal.value
            return
        }
        guard let secret else {
            guard token != nil else {
                throw APIError(status: 401, code: "unauthorized", message: "Not signed in.")
            }
            return
        }

        let task = Task { [client] in
            let response = try await client.token(secret: secret)
            await client.setToken(response.accessToken)
            await MainActor.run {
                self.token = response.accessToken
                self.tokenExpiry = response.expiresAt
            }
        }
        renewal = task
        defer { renewal = nil }
        try await task.value
    }
}
