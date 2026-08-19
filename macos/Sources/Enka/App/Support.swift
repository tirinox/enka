import Foundation

/// `~/Library/Application Support/Enka` — where anything Enka keeps of its own
/// lives. Which is very little: the collection is the server's, and the only
/// things worth writing down here are preferences and a cached queue.
enum Support {
    /// The folder itself, created on first use. Repeated calls are cheap —
    /// `createDirectory` with `withIntermediateDirectories` is content to find
    /// the folder already there.
    static let folder: URL = {
        let fm = FileManager.default
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Enka", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A file inside it, with the folder guaranteed to exist by the time the
    /// path is handed back — which is the only reason this is a function and
    /// not string concatenation at the call site.
    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
