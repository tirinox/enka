import AVFoundation
import Combine
import Foundation

/// Plays one clip at a time.
///
/// Whole clips are fetched into memory rather than streamed. They are a person
/// saying one word — a few kilobytes — and `AVAudioPlayer(data:)` needs no
/// header-setting dance, which an `AVPlayer` pointed at a bearer-protected URL
/// would. Fetched clips are kept, because the same card comes back: the answer
/// side is played the moment it is revealed, and a round trip there is a pause
/// in the middle of the one thing this app is for.
@MainActor
final class AudioPlayback: NSObject, ObservableObject {
    @Published private(set) var playingClipID: String?
    @Published private(set) var isFetching = false

    private var player: AVAudioPlayer?
    private var cache: [String: Data] = [:]
    /// Small on purpose: a study run touches a few dozen clips at most, and
    /// this is a panel, not a library.
    private let cacheLimit = 64
    private var order: [String] = []
    private var task: Task<Void, Never>?

    func play(_ clip: AudioClip, using session: Session) {
        task?.cancel()
        stop()

        if let data = cache[clip.id] {
            start(data, id: clip.id)
            return
        }

        isFetching = true
        task = Task { [weak self] in
            guard let self else { return }
            let data = try? await session.run { try await $0.audio(clipID: clip.id) }
            guard !Task.isCancelled else { return }
            self.isFetching = false
            guard let data else { return }
            self.remember(data, for: clip.id)
            self.start(data, id: clip.id)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingClipID = nil
    }

    /// Everything for one card, in order, with a gap between clips. A card can
    /// carry several takes of the same word; playing only the first would make
    /// the others invisible from the panel.
    func playAll(_ clips: [AudioClip], using session: Session) {
        guard let first = clips.first else { return }
        play(first, using: session)
    }

    /// iOS starts every app in a category that obeys the ring/silent switch, so
    /// a clip of somebody saying a word would be silent for anybody who leaves
    /// the switch flipped — which, for a phone that lives in a pocket, is most
    /// people most of the time. Playback is the whole point of a pronunciation
    /// clip, so the category is raised to match, and ducked rather than mixed:
    /// a word said over a podcast is a word not heard.
    ///
    /// Once per launch, on the first clip rather than at startup, so an app
    /// that never plays anything never touches the audio system at all.
    /// macOS has no such switch and no session to configure.
    private func activateSession() {
        #if os(iOS)
        guard !sessionIsActive else { return }
        sessionIsActive = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    #if os(iOS)
    private var sessionIsActive = false
    #endif

    private func start(_ data: Data, id: String) {
        activateSession()
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            playingClipID = id
        } catch {
            // A clip the system cannot decode is not worth a dialog over the
            // menu bar: the pane's play button simply does nothing, which is
            // what a broken clip looks like anyway.
            playingClipID = nil
        }
    }

    private func remember(_ data: Data, for id: String) {
        cache[id] = data
        order.append(id)
        while order.count > cacheLimit, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}

extension AudioPlayback: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.playingClipID = nil
            self?.player = nil
        }
    }
}
