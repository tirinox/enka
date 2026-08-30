import Foundation

/// An address, a secret, or both, recovered from whatever was on the clipboard.
///
/// Signing in needs two values that live in two different places — the address
/// is in somebody's head and the secret is thirty-two random characters that
/// `make secret` printed into a terminal. In practice they arrive together, in
/// whatever shape the trip made: two lines of a note, a line from `.env`, a URL
/// with the secret hung off the end of it.
///
/// Rather than ask which field a paste was meant for, this reads the text and
/// works it out. The rule that makes that safe is in `PastedCredentials.apply`:
/// a paste only ever moves a field when *both* values were found, and normal
/// typing never produces both.
struct PastedCredentials: Equatable {
    var server: String?
    var secret: String?

    var isComplete: Bool { server != nil && secret != nil }

    // MARK: - Parsing

    static func parse(_ text: String) -> PastedCredentials {
        var server: String?
        var loose: [String] = []

        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let token = strippingEnvelope(String(raw))
            guard !token.isEmpty else { continue }

            if looksLikeAddress(token) {
                let (address, embedded) = splittingEmbeddedSecret(token)
                // First address wins. A second one is far more likely to be
                // noise pasted along with the first — a docs link, a line of
                // log — than a correction.
                if server == nil { server = address }
                if let embedded { loose.append(embedded) }
            } else {
                loose.append(token)
            }
        }

        return PastedCredentials(server: server, secret: pickSecret(from: loose))
    }

    /// The one candidate, or the longest of several.
    ///
    /// Length is the whole heuristic, and it is enough because the competition
    /// is words. Pasting the terminal line `make secret` along with its output
    /// offers "make", "secret" and thirty-two characters of hex; the hex wins
    /// by a factor of five.
    private static func pickSecret(from candidates: [String]) -> String? {
        if candidates.count == 1 { return candidates[0] }
        return candidates.filter { $0.count >= 6 }.max { $0.count < $1.count }
    }

    /// `ENKA_ACCESS_SECRET=abc…` → `abc…`, and quotes and list punctuation off
    /// either end. The `=` is only honoured when what precedes it is shaped
    /// like an environment variable, so a URL's `?secret=` survives to be read
    /// properly below.
    private static func strippingEnvelope(_ token: String) -> String {
        var value = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;•-—"))
        if let equals = value.firstIndex(of: "=") {
            let name = value[value.startIndex..<equals]
            let isEnvName = !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            if isEnvName { value = String(value[value.index(after: equals)...]) }
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    }

    private static func looksLikeAddress(_ token: String) -> Bool {
        if token.contains("://") { return true }
        if token == "localhost" || token.hasPrefix("localhost:") { return true }
        // `host:8010`, which is what people actually write down.
        if let colon = token.lastIndex(of: ":") {
            let port = token[token.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy(\.isNumber) { return true }
        }
        // A dot inside makes it a hostname. A secret is hex or base64 and has
        // none; a bare word has none either, and is treated as a secret.
        return token.dropFirst().dropLast().contains(".")
    }

    /// Pulls a secret back out of an address that carries one.
    ///
    /// Two shapes, because those are the two that survive being sent to
    /// yourself: `http://host:8010#secret`, and `?secret=` / `?token=` on the
    /// query. Anything else is left alone and treated as a plain address.
    private static func splittingEmbeddedSecret(_ token: String) -> (String, String?) {
        guard token.contains("://"), var parts = URLComponents(string: token) else {
            return (token, nil)
        }

        if let fragment = parts.fragment, !fragment.isEmpty {
            parts.fragment = nil
            return (parts.string ?? token, fragment)
        }

        if let items = parts.queryItems,
           let match = items.first(where: { ["secret", "token", "s"].contains($0.name.lowercased()) }),
           let value = match.value, !value.isEmpty {
            parts.queryItems = nil
            return (parts.string ?? token, value)
        }

        return (token, nil)
    }

    // MARK: - Applying

    /// Moves a parsed paste into the two fields, and says whether it did.
    ///
    /// Only a complete pair is allowed to write anything. That is what lets the
    /// same call run on every keystroke without the field fighting the person
    /// typing into it: half-typed text yields at most one of the two values,
    /// and one value is not enough to act on.
    @discardableResult
    static func apply(_ text: String, server: inout String, secret: inout String) -> Bool {
        let parsed = parse(text)
        guard parsed.isComplete, let newServer = parsed.server, let newSecret = parsed.secret else {
            return false
        }
        guard newServer != server || newSecret != secret else { return false }
        server = newServer
        secret = newSecret
        return true
    }
}
