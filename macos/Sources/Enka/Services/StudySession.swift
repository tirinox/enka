import Combine
import Foundation

/// The study loop: one card at a time, revealed and rated.
///
/// The panel is not a study *session* in the Anki sense — there is no deck to
/// finish and no progress bar to fill. It is a place to answer two cards while
/// waiting for a build. So this store holds exactly one card, fetches the next
/// the moment one is answered, and keeps nothing across a fold except what the
/// undo needs.
@MainActor
final class StudySession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        /// A card is up. `revealed` says which half of it is showing.
        case card(StudyCard, revealed: Bool)
        /// Nothing matched the filters — which for `due` mode is the good kind
        /// of nothing, and the pane says so.
        case empty
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.empty, .empty):
                return true
            case let (.card(a, ar), .card(b, br)):
                return a.card.id == b.card.id && ar == br
            case let (.failed(a), .failed(b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remainingDue = 0
    /// What the server said the last answer bought — "8 days". Shown for a
    /// moment under the next card, because the interval is the only feedback
    /// the algorithm ever gives, and it is gone by the time you would go
    /// looking for it.
    @Published private(set) var lastInterval: String?

    @Published var mode: StudyMode = Preferences.studyMode {
        didSet {
            guard mode != oldValue else { return }
            Preferences.studyMode = mode
            restart(force: true)
        }
    }

    @Published var direction: StudyDirection = Preferences.studyDirection {
        didSet {
            guard direction != oldValue else { return }
            Preferences.studyDirection = direction
            // The card on screen keeps the direction it was asked in: swapping
            // sides under someone mid-answer would be a different question with
            // the same card, and they would rate the wrong one.
        }
    }

    /// The card the last answer was recorded against, and the only thing undo
    /// can act on. Cleared once undone, so a second press cannot walk backwards
    /// through a history the panel does not keep.
    @Published private(set) var undoableCard: Card?

    private let session: Session
    private let audio: AudioPlayback
    /// When the current card was first shown, for `elapsed_ms`. Reset on
    /// reveal, not on load: the number the scheduler wants is how long the
    /// answer took, and it is only honest from the moment the prompt was
    /// actually readable.
    private var shownAt: Date?
    private var work: Task<Void, Never>?
    private var isActive = false

    init(session: Session, audio: AudioPlayback) {
        self.session = session
        self.audio = audio
    }

    // MARK: - Lifecycle

    /// Called when the panel opens onto this tab, and when it folds.
    ///
    /// Loading on open rather than keeping a card warm is deliberate: a card
    /// fetched with `mark_shown` is a card the collection now believes was
    /// looked at, and holding one across a fold would quietly inflate
    /// `times_shown` for every hover that happened to land here.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if case .card = phase {} else { restart() }
        } else {
            work?.cancel()
            audio.stop()
        }
    }

    var currentCard: StudyCard? {
        if case let .card(study, _) = phase { return study }
        return nil
    }

    var isRevealed: Bool {
        if case let .card(_, revealed) = phase { return revealed }
        return false
    }

    // MARK: - The loop

    /// Replaces whatever is in flight with a fresh fetch.
    ///
    /// Kept apart from `loadNext` because `loadNext` is also called *from*
    /// inside `work` — answering a card fetches the next one — and cancelling
    /// there would cancel the very task doing the fetching. The symptom was a
    /// rated card followed by an error pane, every time.
    private func restart(force: Bool = false) {
        work?.cancel()
        work = Task { await loadNext(force: force) }
    }

    /// Fetches the next card into `phase`. Cancels nothing: see `restart`.
    func loadNext(force: Bool = false) async {
        if force { lastInterval = nil }
        phase = .loading
        audio.stop()

        let mode = mode
        let direction = direction
        do {
            let next = try await session.run { try await $0.nextCard(mode: mode, direction: direction, tags: []) }
            guard !Task.isCancelled else { return }
            remainingDue = next.remainingDue
            phase = .card(next, revealed: false)
            shownAt = Date()
            autoPlay(for: next, revealed: false)
        } catch let error as APIError where error.isNotFound {
            remainingDue = 0
            phase = .empty
        } catch is CancellationError {
            return
        } catch let error as APIError {
            phase = .failed(error.message)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// What the "try again" button presses. The pane has no business knowing
    /// whether a reload cancels anything.
    func reload() { restart(force: true) }

    /// Space, or a click anywhere on the card. Idempotent, because both of
    /// those can arrive twice for one intention.
    func reveal() {
        guard case let .card(study, revealed) = phase, !revealed else { return }
        phase = .card(study, revealed: true)
        autoPlay(for: study, revealed: true)
    }

    func answer(_ rating: Rating) {
        guard case let .card(study, revealed) = phase else { return }
        // Rating a card whose answer has not been seen is answering a question
        // that was not asked. The key still does something — it reveals — so
        // the digit pressed early is not simply dropped.
        guard revealed else {
            reveal()
            return
        }

        let elapsed = shownAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        let card = study.card
        phase = .loading

        work = Task {
            do {
                let response = try await session.run {
                    try await $0.answer(cardID: card.id, rating: rating, direction: study.direction, elapsedMs: elapsed)
                }
                guard !Task.isCancelled else { return }
                lastInterval = response.intervalHuman
                remainingDue = response.remainingDue
                undoableCard = response.card
                await loadNext()
            } catch is CancellationError {
                return
            } catch let error as APIError {
                // The card stays up. An answer that did not reach the server is
                // an answer the user still has to give, and putting the next
                // card up would silently lose this one.
                phase = .card(study, revealed: true)
                lastInterval = nil
                report(error.message)
            } catch {
                phase = .card(study, revealed: true)
                report(error.localizedDescription)
            }
        }
    }

    /// Takes back the last answer and puts the card back up, already revealed —
    /// undo is pressed because the rating was wrong, not because the card was
    /// unfinished.
    func undo() {
        guard let card = undoableCard else { return }
        work?.cancel()
        phase = .loading

        work = Task {
            do {
                let response = try await session.run { try await $0.undo(cardID: card.id) }
                guard !Task.isCancelled else { return }
                undoableCard = nil
                lastInterval = nil
                remainingDue = (try? await session.run { try await $0.remainingDue() }) ?? remainingDue
                phase = .card(
                    StudyCard(card: response.card, direction: resolveDirection(for: response.card), mode: mode, remainingDue: remainingDue),
                    revealed: true
                )
                shownAt = Date()
            } catch is CancellationError {
                return
            } catch let error as APIError {
                report(error.message)
                await loadNext()
            } catch {
                report(error.localizedDescription)
                await loadNext()
            }
        }
    }

    /// Undo answers with the card but not with a direction, so one is chosen
    /// the way the server would: a card with nothing on the far side can only
    /// be asked term-first.
    private func resolveDirection(for card: Card) -> ReviewDirection {
        guard let definition = card.definition, !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .termToDef
        }
        switch direction {
        case .termToDef: return .termToDef
        case .defToTerm: return .defToTerm
        case .random: return Bool.random() ? .termToDef : .defToTerm
        }
    }

    // MARK: - Errors

    /// A failure that does not take the card away gets a line under it rather
    /// than the whole pane. It clears on the next successful anything.
    @Published private(set) var notice: String?

    private func report(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if notice == message { notice = nil }
        }
    }

    // MARK: - Audio

    /// Plays whichever side has just become readable — the prompt when the card
    /// goes up, the answer when it is revealed. Nothing plays twice: the term
    /// side of a `term_to_def` card is the prompt, so revealing it plays the
    /// definition's clips if there are any, and usually there are not.
    private func autoPlay(for study: StudyCard, revealed: Bool) {
        guard Preferences.autoPlayAudio else { return }
        let side = visibleSide(of: study, revealed: revealed)
        let clips = study.card.clips(for: side)
        guard !clips.isEmpty else { return }
        audio.playAll(clips, using: session)
    }

    /// Which side of the card the given half of the exchange shows.
    func visibleSide(of study: StudyCard, revealed: Bool) -> AudioSide {
        switch (study.direction, revealed) {
        case (.termToDef, false), (.defToTerm, true): return .term
        case (.termToDef, true), (.defToTerm, false): return .definition
        }
    }
}
