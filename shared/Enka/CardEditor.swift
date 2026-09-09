import Combine
import Foundation

/// One card, open for editing — or one that does not exist yet.
///
/// The Mac has no such thing: the panel is four seconds under the notch, and
/// "look here, edit in the web client" was the right trade for a strip of
/// screen that appears on a hover. A phone is the other case. It is where the
/// collection gets tidied — on a sofa, a card at a time — and the thing that
/// was missing was never the screen, it was somewhere to put the whole card.
///
/// So this holds a draft of all six editable fields and sends only what moved.
/// `PATCH /cards/{id}` reads its body with `exclude_unset`, so a save that
/// touched the definition leaves the notes alone even if another client has
/// changed them since.
@MainActor
final class CardEditor: ObservableObject {
    /// The card as the server last described it, or nil when this is a card
    /// being written for the first time.
    @Published private(set) var original: Card?

    @Published var term: String
    @Published var definition: String
    @Published var notes: String
    /// Ordered rather than a set: they are shown in a row, and a row that
    /// reshuffles itself when one is added is a row nobody can aim at.
    @Published var tags: [String]
    @Published var starRating: Int?
    @Published var suspended: Bool

    @Published private(set) var isSaving = false
    @Published private(set) var isDeleting = false
    @Published private(set) var notice: String?

    // MARK: - AI definition
    //
    // Fills the field directly rather than staging a suggestion for
    // accept/discard, exactly as the Mac's Add tab does and unlike its Search
    // tab: this field is already freely editable, so a generated answer is
    // just one more way of arriving at the same text typing would.
    @Published private(set) var isGenerating = false
    @Published var askingNativeLanguage = false
    @Published var nativeLanguageDraft = ""

    private let session: Session

    init(session: Session, card: Card? = nil) {
        self.session = session
        self.original = card
        term = card?.term ?? ""
        definition = card?.definition ?? ""
        notes = card?.notes ?? ""
        tags = card?.tags ?? []
        starRating = card?.starRating
        suspended = card?.suspended ?? false
    }

    var isNew: Bool { original == nil }

    var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether the draft differs from the card it was opened on. A new card is
    /// dirty as soon as it has a term, because there is nothing to differ from.
    var isDirty: Bool {
        guard original != nil else { return !trimmedTerm.isEmpty }
        return !patch.isEmpty
    }

    var canSave: Bool { !trimmedTerm.isEmpty && !isSaving && isDirty }

    /// What changed, and nothing else. Cleared fields are sent as null rather
    /// than omitted — see `CardPatch`, where the two are told apart.
    private var patch: CardPatch {
        var patch = CardPatch()
        guard let original else { return patch }

        if trimmedTerm != original.term { patch.term = trimmedTerm }

        let meaning = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        if meaning != (original.definition ?? "") { patch.definition = .some(meaning.isEmpty ? nil : meaning) }

        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if note != (original.notes ?? "") { patch.notes = .some(note.isEmpty ? nil : note) }

        if starRating != original.starRating { patch.starRating = .some(starRating) }
        if suspended != original.suspended { patch.suspended = suspended }
        // Order is this app's, not the server's, so a reordering is not a
        // change: only the set of names is compared.
        if Set(tags) != Set(original.tags) { patch.tags = tags }

        return patch
    }

    // MARK: - Saving

    /// Returns the saved card, or nil if the save failed — the caller puts it
    /// back into whichever list it came from, and closes on a non-nil answer.
    @discardableResult
    func save() async -> Card? {
        guard !trimmedTerm.isEmpty, !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }

        let meaning = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let saved: Card
            if let original {
                let patch = self.patch
                // Nothing moved: hand back what is already there rather than
                // asking the server to confirm it.
                guard !patch.isEmpty else { return original }
                saved = try await session.run { try await $0.update(cardID: original.id, patch) }
            } else {
                let new = CardCreate(
                    term: trimmedTerm,
                    definition: meaning.isEmpty ? nil : meaning,
                    notes: note.isEmpty ? nil : note,
                    tags: tags.isEmpty ? nil : tags,
                    starRating: starRating,
                    suspended: suspended ? true : nil
                )
                saved = try await session.run { try await $0.create(new) }
            }
            // Re-seeded from the answer, so a second save from the same open
            // editor sends the next delta rather than the same one again.
            adopt(saved)
            notice = nil
            return saved
        } catch {
            announce(error)
            return nil
        }
    }

    /// Soft delete — the row survives as a tombstone, the other clients learn
    /// about it on their next sync, and `LibraryStore` can offer it back.
    func delete() async -> Bool {
        guard let original, !isDeleting else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await session.run { try await $0.deleteCard(id: original.id) }
            return true
        } catch {
            announce(error)
            return false
        }
    }

    private func adopt(_ card: Card) {
        original = card
        term = card.term
        definition = card.definition ?? ""
        notes = card.notes ?? ""
        tags = card.tags
        starRating = card.starRating
        suspended = card.suspended
    }

    // MARK: - Tags

    func toggle(_ name: String) {
        if let index = tags.firstIndex(of: name) {
            tags.remove(at: index)
        } else {
            tags.append(name)
        }
    }

    /// Adds a tag typed rather than picked. The server creates it on first use
    /// — `resolve_tags` on the card endpoints does — so a name that is not on
    /// the tags screen yet is not an error, it is a new tag.
    func add(tag raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !tags.contains(name) else { return }
        tags.append(name)
    }

    func remove(tag name: String) {
        tags.removeAll { $0 == name }
    }

    // MARK: - AI definition

    func generateDefinition(mode: DefinitionMode) {
        let subject = trimmedTerm
        guard !subject.isEmpty, !isGenerating else { return }
        isGenerating = true
        Task {
            do {
                let response = try await session.run { try await $0.generateDefinition(term: subject, mode: mode) }
                // The term can be edited while a local model is still thinking
                // about the last one; an answer for a word no longer on screen
                // is dropped rather than written under a different one.
                if trimmedTerm == subject { definition = response.definition }
            } catch {
                announce(error)
            }
            isGenerating = false
        }
    }

    /// Asks first if nothing is set yet, rather than sending the server a
    /// translation request it would just reject.
    func translateTapped() {
        if let language = session.nativeLanguage, !language.isEmpty {
            generateDefinition(mode: .nativeLanguage)
        } else {
            askingNativeLanguage = true
        }
    }

    func confirmNativeLanguage() {
        let language = nativeLanguageDraft.trimmingCharacters(in: .whitespaces)
        guard !language.isEmpty else { return }
        Task {
            do {
                try await session.setNativeLanguage(language)
                askingNativeLanguage = false
                nativeLanguageDraft = ""
                generateDefinition(mode: .nativeLanguage)
            } catch {
                announce(error)
            }
        }
    }

    // MARK: - Errors

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
