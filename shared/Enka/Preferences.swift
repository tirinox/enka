import Foundation

/// Everything the user can set that is not a secret.
///
/// A thin, typed face over `UserDefaults` rather than `@AppStorage` scattered
/// through the views: three of these are read by the stores, which are not
/// views and have no business owning a property wrapper that redraws one.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let serverURL = "serverURL"
        static let studyMode = "studyMode"
        static let studyDirection = "studyDirection"
        static let autoPlayAudio = "autoPlayAudio"
        static let fillFromClipboard = "fillFromClipboard"
        static let badgeShowsDue = "badgeShowsDue"
        static let tokenExpiry = "tokenExpiresAt"
    }

    /// The address a fresh install starts with, prefilled in the sign-in field.
    ///
    /// CLIENT_DEFAULT_SERVER from .env, which `make mac`, `make ios` and
    /// `make ios-device` write into Info.plist as EnkaDefaultServer. Without
    /// one — a build straight from Xcode, or a .env that does not set it —
    /// it is what `make up` serves on. An address somebody has already
    /// connected to is saved and wins over this either way.
    static let defaultServer: String = {
        let baked = Bundle.main.object(forInfoDictionaryKey: "EnkaDefaultServer") as? String
        let trimmed = baked?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "http://localhost:8010" : trimmed
    }()

    static var serverURL: String {
        get { defaults.string(forKey: Key.serverURL) ?? defaultServer }
        set { defaults.set(newValue, forKey: Key.serverURL) }
    }

    /// The address as a URL, with the shapes people actually type made to work:
    /// a missing scheme, and a trailing slash.
    static func url(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }

    static var serverRoot: URL {
        url(from: serverURL) ?? URL(string: defaultServer)!
    }

    static var studyMode: StudyMode {
        get { StudyMode(rawValue: defaults.string(forKey: Key.studyMode) ?? "") ?? .smart }
        set { defaults.set(newValue.rawValue, forKey: Key.studyMode) }
    }

    static var studyDirection: StudyDirection {
        get { StudyDirection(rawValue: defaults.string(forKey: Key.studyDirection) ?? "") ?? .termToDef }
        set { defaults.set(newValue.rawValue, forKey: Key.studyDirection) }
    }

    /// Defaults to on: a card with audio has it because somebody wanted to hear
    /// the word, and a panel that hides that behind a click is a panel that
    /// makes them click every time.
    static var autoPlayAudio: Bool {
        get { defaults.object(forKey: Key.autoPlayAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoPlayAudio) }
    }

    /// Whether the Add screen may ask the system for what was last copied and
    /// put it in the empty field.
    ///
    /// Defaults to on, because the word is on the clipboard already in the case
    /// this app exists for — you were reading something and selected a word —
    /// and a field that fills itself is the whole gesture saved. It is a switch
    /// rather than a fact because iOS asks before handing anything over, and
    /// somebody who does not want that question does not want it every time
    /// they copy something.
    static var fillFromClipboard: Bool {
        get { defaults.object(forKey: Key.fillFromClipboard) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.fillFromClipboard) }
    }

    /// When the token in the keychain runs out.
    ///
    /// Not a secret — it is a date — and kept out here so that a launch can
    /// tell "the token is still good" from "there is a token and no idea"
    /// without spending a round trip to find out.
    static var tokenExpiry: Date? {
        get { defaults.object(forKey: Key.tokenExpiry) as? Date }
        set { defaults.set(newValue, forKey: Key.tokenExpiry) }
    }

    /// Defaults to on. The count in the menu bar is the one thing that gets a
    /// person to study without deciding to.
    static var badgeShowsDue: Bool {
        get { defaults.object(forKey: Key.badgeShowsDue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.badgeShowsDue) }
    }
}
