import Combine
import Foundation

/// The search tab: "do I have this word, and what did I write for it?"
///
/// Deliberately read-mostly. The collection is edited in the web client, where
/// there is room to think; from a panel that opens on a hover, the useful verbs
/// are look, listen, and suspend — all of them either harmless or one press
/// from being undone.
@MainActor
final class SearchStore: ObservableObject {
    @Published var query = ""
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var exactMatch = false
    @Published private(set) var isSearching = false
    @Published private(set) var notice: String?
    /// The row expanded to show notes and counts. One at a time — the list is
    /// eight rows tall and two open cards would leave room for nothing else.
    @Published var expanded: String? {
        didSet {
            guard oldValue != expanded else { return }
            // A suggestion (and a pending generation) belongs to whichever
            // card was expanded when it started — collapsing or switching
            // rows drops the visible state at once. The in-flight request
            // itself, if any, is left to finish; generateDefinition checks
            // `expanded` again before applying its result, so a response
            // that lands after the switch is discarded, not misattributed
            // to the newly-expanded row.
            suggestion = nil
            isGenerating = false
            askingNativeLanguage = false
            nativeLanguageDraft = ""
        }
    }

    /// AI-generated text for the expanded card, waiting on accept/discard —
    /// never written to the card until accepted. See SearchPane's "accept or
    /// discard, not free-text editing" design: full editing is the web
    /// client's job.
    @Published private(set) var suggestion: String?
    @Published private(set) var isGenerating = false
    /// Shown inline instead of the generate buttons when a translation is
    /// requested and the owner has no native language set yet.
    @Published var askingNativeLanguage = false
    @Published var nativeLanguageDraft = ""

    private let session: Session
    private var work: Task<Void, Never>?

    init(session: Session) {
        self.session = session
    }

    func queryChanged() {
        work?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            hits = []
            exactMatch = false
            isSearching = false
            return
        }
        isSearching = true
        work = Task {
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            do {
                let response = try await session.run { try await $0.search(text, limit: 25) }
                guard !Task.isCancelled else { return }
                hits = response.hits
                exactMatch = response.exactMatch
                notice = nil
            } catch is CancellationError {
                return
            } catch let error as APIError {
                notice = error.message
                hits = []
            } catch {
                notice = error.localizedDescription
                hits = []
            }
            isSearching = false
        }
    }

    func clear() {
        work?.cancel()
        query = ""
        hits = []
        exactMatch = false
        expanded = nil
        notice = nil
    }

    /// Suspending is the one change this tab makes, and it is made optimistically:
    /// the row flips at once and the server is told after. A failure puts it
    /// back and says so, which is a rarer event than the round trip is a wait.
    func toggleSuspended(_ card: Card) {
        let wanted = !card.suspended
        replace(cardID: card.id) { $0.with(suspended: wanted) }
        Task {
            do {
                let updated = try await session.run { try await $0.update(cardID: card.id, suspended: wanted) }
                replace(cardID: card.id) { _ in updated }
            } catch let error as APIError {
                replace(cardID: card.id) { $0.with(suspended: !wanted) }
                notice = error.message
            } catch {
                replace(cardID: card.id) { $0.with(suspended: !wanted) }
                notice = error.localizedDescription
            }
        }
    }

    // MARK: - AI definition

    func generateDefinition(for card: Card, mode: DefinitionMode) {
        isGenerating = true
        suggestion = nil
        let cardID = card.id
        Task {
            do {
                let response = try await session.run { try await $0.generateDefinition(cardID: cardID, mode: mode) }
                // The row this was for may have collapsed or a different one
                // may have opened while the request was in flight — a stale
                // answer is dropped rather than shown under the wrong card.
                guard expanded == cardID else { return }
                suggestion = response.definition
                isGenerating = false
            } catch let error as APIError {
                guard expanded == cardID else { return }
                notice = error.message
                isGenerating = false
            } catch {
                guard expanded == cardID else { return }
                notice = error.localizedDescription
                isGenerating = false
            }
        }
    }

    /// Asks first if nothing is set yet, rather than sending the server a
    /// translation request it would just reject.
    func translateTapped(for card: Card) {
        if let language = session.nativeLanguage, !language.isEmpty {
            generateDefinition(for: card, mode: .nativeLanguage)
        } else {
            askingNativeLanguage = true
        }
    }

    func confirmNativeLanguage(for card: Card) {
        let language = nativeLanguageDraft.trimmingCharacters(in: .whitespaces)
        guard !language.isEmpty else { return }
        let cardID = card.id
        Task {
            do {
                // Not card-scoped — the setting is saved regardless of which
                // row is expanded by the time this resolves. Only the
                // prompt's own UI state is guarded, so a switch mid-flight
                // doesn't dismiss a different row's still-open prompt.
                try await session.setNativeLanguage(language)
                if expanded == cardID {
                    askingNativeLanguage = false
                    nativeLanguageDraft = ""
                }
                generateDefinition(for: card, mode: .nativeLanguage)
            } catch let error as APIError {
                if expanded == cardID { notice = error.message }
            } catch {
                if expanded == cardID { notice = error.localizedDescription }
            }
        }
    }

    func acceptSuggestion(for card: Card) {
        guard let suggestion else { return }
        let cardID = card.id
        Task {
            do {
                let updated = try await session.run { try await $0.update(cardID: cardID, definition: suggestion) }
                // The save applies to the list regardless of what's expanded
                // by now; only the pending-suggestion UI state is guarded.
                replace(cardID: cardID) { _ in updated }
                if expanded == cardID { self.suggestion = nil }
            } catch let error as APIError {
                if expanded == cardID { notice = error.message }
            } catch {
                if expanded == cardID { notice = error.localizedDescription }
            }
        }
    }

    func discardSuggestion() {
        suggestion = nil
    }

    private func replace(cardID: String, _ transform: (Card) -> Card) {
        guard let index = hits.firstIndex(where: { $0.card.id == cardID }) else { return }
        let hit = hits[index]
        hits[index] = SearchHit(card: transform(hit.card), score: hit.score, matchedSide: hit.matchedSide)
    }
}

extension Card {
    /// A copy with one field moved. Needed only for the optimistic suspend, and
    /// spelled out rather than made general: `Card` is a wire type, and a
    /// mutable one would invite the panel to start believing its own edits.
    func with(suspended: Bool) -> Card {
        Card(
            id: id, term: term, definition: definition, notes: notes, tags: tags,
            starRating: starRating, suspended: suspended, timesShown: timesShown,
            lapses: lapses, accuracy: accuracy, dueAt: dueAt, lastReviewAt: lastReviewAt,
            audioClips: audioClips
        )
    }
}
