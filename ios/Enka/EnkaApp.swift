import SwiftUI

/// The iOS client.
///
/// Everything below `shared/Enka` — the API client, the models, the study
/// session — is the same code the Mac panel runs, compiled into this target
/// rather than linked. Only the views under `ios/Enka` are new, because only
/// the views were ever platform-specific: the Mac's are built for a keyboard
/// and a strip of screen under the notch, and a phone has neither.
@main
struct EnkaApp: App {
    @StateObject private var session: Session
    @StateObject private var audio: AudioPlayback
    @StateObject private var study: StudySession

    /// Built here rather than in a view, because `StudySession` needs the other
    /// two and there is exactly one of each for the life of the app. A view
    /// that made its own would make a second one every time it was rebuilt.
    init() {
        let session = Session()
        let audio = AudioPlayback()
        _session = StateObject(wrappedValue: session)
        _audio = StateObject(wrappedValue: audio)
        _study = StateObject(wrappedValue: StudySession(session: session, audio: audio))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(audio)
                .environmentObject(study)
                // Before anything is drawn, because the keychain usually
                // already holds a token and the sign-in screen would otherwise
                // flash past on every cold launch.
                .task { await session.restore() }
        }
    }
}
