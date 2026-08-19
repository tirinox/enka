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
    @Published var expanded: String?

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
