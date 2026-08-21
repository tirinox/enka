import Foundation

/// Everything the panel knows about failure.
///
/// The backend answers every failure with the same envelope —
/// `{"error": {"code": …, "message": …, "details": {…}}}` — so this is the only
/// place that has to know how to read it. Everything above catches `APIError`
/// and shows `message`.
struct APIError: Error, LocalizedError {
    let status: Int
    let code: String
    let message: String

    var errorDescription: String? { message }

    /// The token is gone or expired — the session should re-authenticate.
    var isAuthFailure: Bool { status == 401 || status == 403 }

    /// `GET /study/next` answers 404 when nothing matches the filters. That is
    /// an empty queue, not a fault, and the study pane says so in words rather
    /// than in red.
    var isNotFound: Bool { status == 404 }

    /// No server at the other end. Told apart from an HTTP failure because the
    /// remedy is different: check the address, not the secret.
    var isOffline: Bool { status == 0 }

    static func offline(_ message: String = "Cannot reach the server.") -> APIError {
        APIError(status: 0, code: "network_error", message: message)
    }
}

/// The one HTTP client.
///
/// An actor, not a `@MainActor` object: every call is a round trip, and the
/// decoding that follows has no business on the thread drawing the panel. The
/// stores above are main-actor and `await` into here.
actor APIClient {
    /// Where the server lives — the root, not `/api/v1`. Held as the root
    /// because `/health` sits outside the versioned prefix, and because the
    /// settings tab asks the user for exactly this: the address they would type
    /// into a browser.
    private var root: URL
    private var token: String?

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(root: URL) {
        self.root = root

        let config = URLSessionConfiguration.ephemeral
        // The panel is a hover away from the user's attention: a request that
        // has not answered in ten seconds has already lost, and failing fast
        // lets the pane say so while they are still looking at it.
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        encoder = JSONEncoder()
    }

    func setRoot(_ url: URL) { root = url }
    func setToken(_ value: String?) { token = value }

    // MARK: - Dates
    //
    // Pydantic hands back ISO 8601 with microseconds and, depending on the
    // column, either a `Z` or a `+00:00` offset — and `study/next` can answer
    // with a `due_at` that has no fractional part at all. `ISO8601DateFormatter`
    // matches exactly one of those shapes per configuration, so it is asked
    // twice rather than trusted once.

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    @Sendable private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let date = withFraction.date(from: raw) ?? withoutFraction.date(from: raw) {
            return date
        }
        // Some timestamps arrive naive — no offset at all — because the column
        // was written before the backend settled on tz-aware datetimes. UTC is
        // the only reading that is ever right for this API.
        if let date = withoutFraction.date(from: raw + "Z") {
            return date
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(raw)")
        )
    }

    // MARK: - Requests

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String?
            let message: String?
        }
        let error: Body?
    }

    /// Query items, skipping anything empty. Repeated keys for arrays, which is
    /// how FastAPI reads a list out of a query string.
    ///
    /// `versioned` is false for exactly one endpoint — `/health` — which is the
    /// only thing the server exposes outside `/api/v1`.
    private func url(_ path: String, _ query: [(String, String?)] = [], versioned: Bool = true) -> URL {
        let prefix = versioned ? root.appendingPathComponent("api/v1") : root
        let base = prefix.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        let items = query.compactMap { key, value -> URLQueryItem? in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        guard !items.isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        components.queryItems = items
        return components.url ?? base
    }

    private func send<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [(String, String?)] = [],
        body: Data? = nil,
        anonymous: Bool = false,
        versioned: Bool = true
    ) async throws -> T {
        let data = try await raw(path, method: method, query: query, body: body, anonymous: anonymous, versioned: versioned)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError(status: 200, code: "decode_error", message: "The server answered in a shape this app does not know.")
        }
    }

    /// The bytes, undecoded. Used for audio, and by `send` for everything else.
    private func raw(
        _ path: String,
        method: String = "GET",
        query: [(String, String?)] = [],
        body: Data? = nil,
        anonymous: Bool = false,
        versioned: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: url(path, query, versioned: versioned))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !anonymous {
            guard let token else {
                throw APIError(status: 401, code: "unauthorized", message: "Not signed in.")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // Re-thrown as a cancellation rather than as itself, so the stores
            // can tell "I cancelled this" from "the server is unreachable" with
            // one `catch is CancellationError`. A cancelled request that gets
            // reported as a network failure paints an error pane over a screen
            // the user has already moved on from.
            throw CancellationError()
        } catch {
            throw APIError.offline()
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.offline("The server answered something that is not HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw APIError(
                status: http.statusCode,
                code: envelope?.error?.code ?? "error",
                message: envelope?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        return data
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    // MARK: - Endpoints

    /// Unauthenticated, and the only call the settings tab can make before a
    /// secret has been typed — so "is this address right?" and "is this secret
    /// right?" stay two separate questions with two separate answers.
    func health() async throws -> HealthResponse {
        try await send("health", anonymous: true, versioned: false)
    }

    func token(secret: String) async throws -> TokenResponse {
        struct Body: Encodable { let secret: String }
        return try await send("auth/token", method: "POST", body: try encode(Body(secret: secret)), anonymous: true)
    }

    func me() async throws -> MeResponse {
        try await send("auth/me")
    }

    func updateMe(nativeLanguage: String) async throws -> MeResponse {
        struct Body: Encodable {
            let nativeLanguage: String
            enum CodingKeys: String, CodingKey { case nativeLanguage = "native_language" }
        }
        return try await send(
            "auth/me", method: "PATCH", body: try encode(Body(nativeLanguage: nativeLanguage))
        )
    }

    // Study

    func nextCard(mode: StudyMode, direction: StudyDirection, tags: [String]) async throws -> StudyCard {
        try await send("study/next", query: [("mode", mode.rawValue), ("direction", direction.rawValue)]
            + tags.map { ("tags", $0) })
    }

    /// Nothing is marked as shown by this one, which is what makes it the right
    /// call for the badge in the menu bar: asking how much is due must not be
    /// the same as having looked at a card.
    func remainingDue() async throws -> Int {
        let queue: StudyQueue = try await send("study/queue", query: [("limit", "1")])
        return queue.remainingDue
    }

    func answer(cardID: String, rating: Rating, direction: ReviewDirection, elapsedMs: Int?) async throws -> AnswerResponse {
        let body = AnswerRequest(rating: rating, direction: direction, elapsedMs: elapsedMs)
        return try await send("study/\(cardID)/answer", method: "POST", body: try encode(body))
    }

    func undo(cardID: String) async throws -> UndoResponse {
        try await send("study/\(cardID)/undo", method: "POST")
    }

    // Cards

    func search(_ query: String, limit: Int = 20) async throws -> SearchResponse {
        try await send("cards/search", query: [("q", query), ("limit", String(limit))])
    }

    func create(_ card: CardCreate) async throws -> Card {
        try await send("cards", method: "POST", body: try encode(card))
    }

    func update(cardID: String, suspended: Bool) async throws -> Card {
        struct Patch: Encodable { let suspended: Bool }
        return try await send("cards/\(cardID)", method: "PATCH", body: try encode(Patch(suspended: suspended)))
    }

    func update(cardID: String, definition: String) async throws -> Card {
        struct Patch: Encodable { let definition: String }
        return try await send("cards/\(cardID)", method: "PATCH", body: try encode(Patch(definition: definition)))
    }

    /// Not card-scoped — works on a term that hasn't been saved yet, which is
    /// what the Add tab needs. Never persisted server-side; the caller saves
    /// the result itself (as the definition it's about to create, or via
    /// `update(cardID:definition:)`) if it wants to keep it.
    func generateDefinition(term: String, mode: DefinitionMode) async throws -> DefinitionGenerateResponse {
        struct Body: Encodable { let term: String; let mode: DefinitionMode }
        return try await send(
            "definitions/generate", method: "POST", body: try encode(Body(term: term, mode: mode))
        )
    }

    func tags() async throws -> [Tag] {
        try await send("tags")
    }

    func createTag(name: String, color: String?) async throws -> Tag {
        struct Body: Encodable {
            let name: String
            let color: String?
        }
        return try await send("tags", method: "POST", body: try encode(Body(name: name, color: color)))
    }

    /// `PATCH /tags/{id}` reads its payload with `exclude_unset`, so a field
    /// left out is a field left alone — and clearing a colour therefore means
    /// sending `"color": null`, not sending nothing. Swift's `JSONEncoder`
    /// drops nil optionals by default, which is exactly the wrong default here,
    /// so the two intentions are held apart by a double optional and written
    /// out by hand.
    func updateTag(id: String, name: String?, color: String??) async throws -> Tag {
        struct Body: Encodable {
            let name: String?
            let color: String??

            enum CodingKeys: String, CodingKey { case name, color }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(name, forKey: .name)
                // Present-but-nil encodes as JSON null; absent stays absent.
                if let color { try container.encode(color, forKey: .color) }
            }
        }
        return try await send("tags/\(id)", method: "PATCH", body: try encode(Body(name: name, color: color)))
    }

    func deleteTag(id: String) async throws {
        // 204, so there is no body to decode — `raw` is asked directly rather
        // than making every no-content endpoint invent a type to be empty in.
        _ = try await raw("tags/\(id)", method: "DELETE")
    }

    // Stats

    func stats() async throws -> StatsResponse {
        try await send("stats", query: [("leech_limit", "5")])
    }

    // Audio

    /// Fetched whole rather than streamed, and with the ordinary bearer token
    /// rather than a media-scoped one. The web client needs `?token=` because an
    /// `<audio src>` cannot set headers; `URLSession` can, so the short-lived
    /// token endpoint buys nothing here — and a clip of somebody saying one word
    /// is a few kilobytes.
    func audio(clipID: String) async throws -> Data {
        try await raw("audio/\(clipID)")
    }
}
