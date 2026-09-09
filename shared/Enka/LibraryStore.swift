import Combine
import Foundation

/// The collection as a list: browse it, search it, and act on a row.
///
/// Two endpoints answer two different questions and this store picks between
/// them by what is in the field. Empty, it browses — `GET /cards`, newest
/// first, a page at a time, narrowed by a tag. Typed into, it searches —
/// `GET /cards/search`, the trigram one, which tolerates typos and accents and
/// is the only way to find a word you half-remember.
///
/// Unlike the Mac's `SearchStore`, which is read-mostly because the panel is
/// four seconds of somebody's attention, this one is where cards are actually
/// changed: a phone is where the collection gets tidied, on a sofa, and the
/// suspend, the delete and the undo behind it all live here.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var query = ""
    /// One tag at a time. A phone has room for a row of chips and no room for
    /// the "any of these / all of these" question a second one would raise.
    @Published var tagFilter: String? {
        didSet {
            guard tagFilter != oldValue else { return }
            refresh()
        }
    }

    @Published private(set) var cards: [Card] = []
    /// How many the server says match, which is what tells a page it is not the
    /// last one. In search mode it is just the number of hits.
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var notice: String?

    /// Whether the rows are search hits rather than a page of the collection.
    /// The distinction is visible: hits do not paginate, and their order is
    /// similarity rather than recency.
    @Published private(set) var isSearching = false
    /// The search endpoint's headline signal, carried through for the row that
    /// says "you already have this".
    @Published private(set) var exactMatch = false

    /// The last card deleted, kept for as long as the undo offer stands.
    ///
    /// Deletes are soft, so undo is a real `POST /cards/{id}/restore` rather
    /// than a local trick — which is what makes it safe to offer from a swipe.
    @Published private(set) var lastDeleted: Card?

    private let session: Session
    private var work: Task<Void, Never>?
    private var paging: Task<Void, Never>?
    private var undoOffer: Task<Void, Never>?
    private var hasLoaded = false

    private let pageSize = 40

    init(session: Session) {
        self.session = session
    }

    var canLoadMore: Bool { !isSearching && cards.count < total }

    /// Read on the way into the tab, once. A list that refetched on every tab
    /// switch would throw away the scroll position of somebody who is going
    /// back and forth between a card and the study screen.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        refresh()
    }

    /// Runs on every keystroke, but only after the typing stops — a trigram
    /// search per character is work the server does not need, and a list that
    /// rewrites itself mid-word is a list nothing can be tapped in.
    func queryChanged() {
        work?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        work = Task {
            try? await Task.sleep(for: .milliseconds(text.isEmpty ? 0 : 240))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    func refresh() {
        work?.cancel()
        work = Task { await load() }
    }

    /// The same fetch the pull-to-refresh gesture waits on, so the spinner
    /// stays up until there is something new under it.
    func reload() async {
        work?.cancel()
        await load()
    }

    private func load() async {
        // Whatever page was in flight belonged to the list that is being
        // replaced; its rows would land under a different query.
        paging?.cancel()
        paging = nil
        isLoadingMore = false
        hasLoaded = true
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = text.count >= 2
        isLoading = cards.isEmpty || searching != isSearching
        defer { isLoading = false }

        do {
            if searching {
                let response = try await session.run { try await $0.search(text, limit: 50) }
                guard !Task.isCancelled else { return }
                isSearching = true
                exactMatch = response.exactMatch
                // The tag filter is a browsing tool; the search endpoint takes
                // no tags, so it is applied here rather than silently ignored.
                let hits = response.hits.map(\.card)
                cards = tagFilter.map { name in hits.filter { $0.tags.contains(name) } } ?? hits
                total = cards.count
            } else {
                let page = try await session.run {
                    try await $0.cards(
                        matching: text.isEmpty ? nil : text,
                        tags: tagFilter.map { [$0] } ?? [],
                        limit: pageSize
                    )
                }
                guard !Task.isCancelled else { return }
                isSearching = false
                exactMatch = false
                cards = page.items
                total = page.total
            }
            notice = nil
        } catch is CancellationError {
            return
        } catch {
            announce(error)
        }
    }

    /// The next page, when the list is browsed to its end. Never in search
    /// mode: fifty fuzzy hits is already more than anybody scrolls through, and
    /// the endpoint has no offset.
    func loadMore() {
        guard canLoadMore, !isLoadingMore, paging == nil else { return }
        let offset = cards.count
        isLoadingMore = true
        paging = Task {
            defer {
                isLoadingMore = false
                paging = nil
            }
            do {
                let page = try await session.run {
                    try await $0.cards(
                        matching: nil,
                        tags: tagFilter.map { [$0] } ?? [],
                        limit: pageSize,
                        offset: offset
                    )
                }
                guard !Task.isCancelled else { return }
                // Cards created while somebody was scrolling shift the window,
                // so the same card can arrive twice. Dropping the duplicates
                // beats a list with two of something in it.
                let known = Set(cards.map(\.id))
                cards.append(contentsOf: page.items.filter { !known.contains($0.id) })
                total = page.total
            } catch is CancellationError {
                return
            } catch {
                announce(error)
            }
        }
    }

    // MARK: - Acting on a row

    /// Optimistic, like the Mac's: the row flips at once and the server is told
    /// after. A failure puts it back and says so, which is a rarer event than
    /// the round trip is a wait.
    func toggleSuspended(_ card: Card) {
        let wanted = !card.suspended
        apply(card.with(suspended: wanted))
        Task {
            do {
                let updated = try await session.run { try await $0.update(cardID: card.id, suspended: wanted) }
                apply(updated)
            } catch {
                apply(card.with(suspended: !wanted))
                announce(error)
            }
        }
    }

    /// Soft-deletes, and holds the card for a moment in case that was a thumb
    /// rather than a decision.
    func delete(_ card: Card) {
        let index = cards.firstIndex { $0.id == card.id }
        cards.removeAll { $0.id == card.id }
        total = max(0, total - 1)
        Task {
            do {
                try await session.run { try await $0.deleteCard(id: card.id) }
                offerUndo(of: card)
            } catch {
                // Put it back where it was, not at the end: a list that
                // reorders itself on a failed delete is a list that lost track
                // of what was where.
                if let index, index <= cards.count {
                    cards.insert(card, at: index)
                } else {
                    cards.append(card)
                }
                total += 1
                announce(error)
            }
        }
    }

    func undoDelete() {
        guard let card = lastDeleted else { return }
        undoOffer?.cancel()
        lastDeleted = nil
        Task {
            do {
                let restored = try await session.run { try await $0.restoreCard(id: card.id) }
                insert(restored)
            } catch {
                announce(error)
            }
        }
    }

    private func offerUndo(of card: Card) {
        undoOffer?.cancel()
        lastDeleted = card
        undoOffer = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            lastDeleted = nil
        }
    }

    // MARK: - Keeping the list honest

    /// A card that changed somewhere else in the app — the editor, the study
    /// screen — put back into whichever row is showing it.
    func apply(_ card: Card) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[index] = card
    }

    /// A card that has just been created, at the top, where "newest first"
    /// would have put it anyway.
    func insert(_ card: Card) {
        guard !cards.contains(where: { $0.id == card.id }) else {
            apply(card)
            return
        }
        cards.insert(card, at: 0)
        total += 1
    }

    func remove(id: String) {
        guard cards.contains(where: { $0.id == id }) else { return }
        cards.removeAll { $0.id == id }
        total = max(0, total - 1)
    }

    /// Keeps the filter honest across an edit made on the tags screen — a tag
    /// renamed there would otherwise leave this list filtered by a name the
    /// server no longer knows, which shows as an empty collection.
    func reconcile(with tags: [Tag]) {
        guard let name = tagFilter, !tags.contains(where: { $0.name == name }) else { return }
        tagFilter = nil
    }

    private func announce(_ error: Error) {
        let message = (error as? APIError)?.message ?? error.localizedDescription
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if notice == message { notice = nil }
        }
    }
}
