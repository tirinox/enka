import Combine
import Foundation

/// The tag list, and the four things one does to it.
///
/// Shared rather than owned by a pane: the add tab shows the same tags as
/// chips, and a tag renamed on one tab must not still be showing its old name
/// on the other. One store, one list, one refresh.
@MainActor
final class TagStore: ObservableObject {
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var isLoading = false
    @Published private(set) var notice: String?
    /// The tag whose row is currently being edited, and the tag whose deletion
    /// is waiting to be confirmed. Held here rather than in the view so that
    /// leaving the tab and coming back does not find a row half-renamed.
    @Published var editing: String?
    @Published var confirmingDelete: String?
    /// Rows with a request in flight, so each can show it without the whole
    /// list going grey.
    @Published private(set) var busy: Set<String> = []

    /// The web client's eight. Short on purpose: a colour picker is a lot of
    /// ceremony for something used this casually, and the two clients showing
    /// different palettes would mean a tag coloured here has no swatch there.
    static let palette = [
        "#d97757", "#c9954f", "#77a37b", "#6d94bd",
        "#a87fb5", "#5fa8a0", "#c96b8e", "#8a8f98",
    ]

    private let session: Session
    private var work: Task<Void, Never>?

    init(session: Session) {
        self.session = session
    }

    /// Read on the way into a tab that shows tags rather than kept fresh: they
    /// change a few times a month, and a panel that polls them is polling for
    /// nothing most days.
    func refresh() {
        work?.cancel()
        isLoading = tags.isEmpty
        work = Task {
            do {
                let fetched = try await session.run { try await $0.tags() }
                guard !Task.isCancelled else { return }
                tags = fetched
                notice = nil
            } catch is CancellationError {
                return
            } catch {
                announce(error)
            }
            isLoading = false
        }
    }

    /// Most-used first, which is the order the add tab wants for its chips and
    /// the order this tab wants for its rows — the tag you reach for is the one
    /// you have reached for before.
    var byUse: [Tag] {
        tags.sorted {
            ($0.cardCount ?? 0, $1.name.lowercased()) > ($1.cardCount ?? 0, $0.name.lowercased())
        }
    }

    // MARK: - Writing
    //
    // None of these are optimistic. Tag names are unique per owner and the
    // server is the only thing that knows it — a rename that shows as done and
    // then springs back a moment later because something else already had that
    // name is worse than a row that is briefly busy.

    func create(name: String, color: String?) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let created = try await session.run { try await $0.createTag(name: trimmed, color: color) }
            // Rebuilt rather than appended as-is: `POST /tags` answers with a
            // tag and no count, and a fresh tag has no cards on it anyway.
            tags.append(Tag(id: created.id, name: created.name, color: created.color, cardCount: 0))
            notice = nil
            return true
        } catch {
            announce(error)
            return false
        }
    }

    func rename(_ tag: Tag, to name: String, color: String??) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nameChanged = trimmed != tag.name
        guard nameChanged || color != nil else {
            editing = nil
            return
        }

        busy.insert(tag.id)
        defer { busy.remove(tag.id) }
        do {
            let updated = try await session.run {
                try await $0.updateTag(id: tag.id, name: nameChanged ? trimmed : nil, color: color)
            }
            replace(tag.id) {
                // The count comes from the list endpoint and is not in the
                // PATCH response; the old one is still right, because renaming
                // a tag does not move any cards.
                Tag(id: updated.id, name: updated.name, color: updated.color, cardCount: $0.cardCount)
            }
            editing = nil
            notice = nil
        } catch {
            announce(error)
        }
    }

    /// Deletes the label. The cards keep everything else — the backend says so
    /// in as many words, and so does the pane before it asks.
    func delete(_ tag: Tag) async {
        busy.insert(tag.id)
        defer { busy.remove(tag.id) }
        do {
            try await session.run { try await $0.deleteTag(id: tag.id) }
            tags.removeAll { $0.id == tag.id }
            confirmingDelete = nil
            editing = nil
            notice = nil
        } catch {
            announce(error)
        }
    }

    // MARK: - Plumbing

    private func replace(_ id: String, _ transform: (Tag) -> Tag) {
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[index] = transform(tags[index])
    }

    private func announce(_ error: Error) {
        notice = (error as? APIError)?.message ?? error.localizedDescription
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if notice == (error as? APIError)?.message { notice = nil }
        }
    }
}
