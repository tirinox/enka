import Combine
import Foundation

/// The add tab: type a word, press return, carry on with your day.
///
/// The whole reason this app is in the notch rather than in a window. You meet
/// a word, you have three seconds of attention for it, and anything that costs
/// more than a hover and a line of typing does not get done. The definition is
/// optional on purpose — the API allows a card with an empty one, and filling
/// it in later, at a desk, is the intended workflow.
@MainActor
final class CaptureStore: ObservableObject {
    @Published var term = ""
    @Published var definition = ""
    @Published var selectedTags: Set<String> = []

    /// What the collection already has for what is being typed. The point of
    /// the endpoint, and the point of this tab: half of adding a word is
    /// finding out you added it in March.
    @Published private(set) var duplicate: Card?
    @Published private(set) var nearby: [Card] = []
    @Published private(set) var isSaving = false
    @Published private(set) var notice: String?
    /// The card just saved, held only long enough to show a line confirming it.
    @Published private(set) var justSaved: String?

    // MARK: - AI definition
    //
    // Unlike Search's read-mostly rows, this tab's definition field is
    // already freely editable — so a generated suggestion just fills it
    // directly, the same as typing would, rather than needing its own
    // accept/discard step.
    @Published private(set) var isGenerating = false
    @Published var askingNativeLanguage = false
    @Published var nativeLanguageDraft = ""

    private let session: Session
    private var lookup: Task<Void, Never>?
    private var noticeClear: Task<Void, Never>?

    init(session: Session) {
        self.session = session
    }

    var canSave: Bool {
        !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    /// Runs on every keystroke, but only after the typing stops. Two reasons,
    /// and the second is the real one: a trigram search per character is work
    /// the server does not need, and a duplicate warning that appears while the
    /// word is a third typed is a warning about a different word.
    func lookupChanged() {
        lookup?.cancel()
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            duplicate = nil
            nearby = []
            return
        }
        lookup = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            guard let response = try? await session.run({ try await $0.search(query, limit: 4) }) else { return }
            guard !Task.isCancelled else { return }
            // `exact_match` is about the query, so the card it refers to is
            // whichever hit matches it outright — the server does not point at
            // one, and the top hit by score is it.
            duplicate = response.exactMatch ? response.hits.first?.card : nil
            nearby = response.exactMatch ? Array(response.hits.dropFirst().prefix(3)).map(\.card)
                                         : response.hits.prefix(3).map(\.card)
        }
    }

    /// Saves, then clears and stays put. The tab is for adding words, plural:
    /// clearing the fields and keeping the keyboard is the difference between
    /// adding one word and adding the four you met in a paragraph.
    func save() {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return }
        let meaning = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        let card = CardCreate(
            term: trimmed,
            definition: meaning.isEmpty ? nil : meaning,
            notes: nil,
            tags: selectedTags.isEmpty ? nil : Array(selectedTags)
        )

        isSaving = true
        Task {
            do {
                let created = try await session.run { try await $0.create(card) }
                term = ""
                definition = ""
                duplicate = nil
                nearby = []
                askingNativeLanguage = false
                nativeLanguageDraft = ""
                justSaved = created.term
                announce(nil)
                Task {
                    try? await Task.sleep(for: .seconds(2.4))
                    if justSaved == created.term { justSaved = nil }
                }
            } catch let error as APIError {
                announce(error.message)
            } catch {
                announce(error.localizedDescription)
            }
            isSaving = false
        }
    }

    func generateDefinition(mode: DefinitionMode) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        Task {
            do {
                let response = try await session.run { try await $0.generateDefinition(term: trimmed, mode: mode) }
                // A fast typist can move on to a different word while a local
                // model is still thinking about the last one — an answer for
                // a term that is no longer on screen is dropped, not applied.
                if term.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                    definition = response.definition
                }
            } catch let error as APIError {
                announce(error.message)
            } catch {
                announce(error.localizedDescription)
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
            } catch let error as APIError {
                announce(error.message)
            } catch {
                announce(error.localizedDescription)
            }
        }
    }

    /// Keeps the selection honest across an edit made on the tags tab. A name
    /// picked here and then renamed there would otherwise be sent with the next
    /// card, which creates the old tag again — undoing the rename by the back
    /// door.
    func reconcile(with tags: [Tag]) {
        let names = Set(tags.map(\.name))
        selectedTags.formIntersection(names)
    }

    /// Clears both fields. Escape's job, and the reason Escape does not close
    /// the panel from this tab: the field is the thing in front of you, so it
    /// is the thing the key should empty.
    func clear() {
        term = ""
        definition = ""
        duplicate = nil
        nearby = []
        notice = nil
        askingNativeLanguage = false
        nativeLanguageDraft = ""
    }

    private func announce(_ message: String?) {
        noticeClear?.cancel()
        notice = message
        guard message != nil else { return }
        noticeClear = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}
