import SwiftUI
import UIKit

/// One card, whole: both sides, the notes, the tags, the grade, and the switch
/// that takes it out of rotation.
///
/// The same sheet writes a new card and edits an existing one — the only
/// difference is what it opened on, and the four sections that need a card to
/// exist before they mean anything. Saving sends only what moved, because
/// `PATCH /cards/{id}` reads its body with `exclude_unset`: a card edited here
/// while the web client has it open loses nothing that was not touched.
struct CardEditorView: View {
    enum Outcome {
        case saved(Card)
        case deleted(String)
    }

    @StateObject private var editor: CardEditor
    @ObservedObject private var tagStore: TagStore
    @ObservedObject private var audio: AudioPlayback
    private let session: Session
    private let onFinish: (Outcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    @State private var tagDraft = ""
    @State private var isConfirmingDelete = false
    @State private var isConfirmingDiscard = false

    private enum Field: Hashable { case term, definition, notes, tag, nativeLanguage }

    init(
        session: Session,
        card: Card?,
        tags: TagStore,
        audio: AudioPlayback,
        onFinish: @escaping (Outcome) -> Void
    ) {
        _editor = StateObject(wrappedValue: CardEditor(session: session, card: card))
        self.tagStore = tags
        self.audio = audio
        self.session = session
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            Form {
                cardSection
                notesSection
                tagsSection
                gradeSection
                if let card = editor.original {
                    audioSection(card)
                    factsSection(card)
                    deleteSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editor.isNew ? "New card" : "Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if editor.isDirty { isConfirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editor.isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .fontWeight(.semibold)
                            .disabled(!editor.canSave)
                    }
                }
            }
            // A sheet dragged away by accident should not take an edit with
            // it. Dirty, the drag is refused and Cancel asks; clean, it closes
            // the way any sheet does.
            .interactiveDismissDisabled(editor.isDirty)
            .confirmationDialog(
                "Discard your changes?",
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .tint(Theme.accent)
        .onAppear { if editor.isNew { focus = .term } }
        .onChange(of: editor.askingNativeLanguage) { _, asking in
            if asking { focus = .nativeLanguage }
        }
    }

    // MARK: - The two sides

    private var cardSection: some View {
        Section {
            TextField("Term", text: $editor.term, axis: .vertical)
                .font(.system(.title3, design: .serif).weight(.medium))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .term)

            GrowingTextField(
                placeholder: "Meaning — it can stay empty",
                text: $editor.definition,
                minHeight: 72
            )
            .focused($focus, equals: .definition)

            aiRow
        } header: {
            Text("Card")
        } footer: {
            if editor.isNew {
                Text("A card with no meaning yet is a card you can fill in later. It will still be asked term-first.")
            }
        }
        .listRowBackground(Theme.surface)
    }

    /// Define, translate, or — the one time this sheet asks for something else
    /// — which language "translate" means. Fills the field directly rather than
    /// staging a suggestion: the field is editable anyway, so a generated
    /// answer is one more way of arriving at the text typing would.
    @ViewBuilder private var aiRow: some View {
        if editor.isGenerating {
            HStack(spacing: 8) {
                ProgressView()
                Text("Thinking…")
                    .font(.footnote)
                    .foregroundStyle(Theme.textFaint)
            }
        } else if editor.askingNativeLanguage {
            HStack(spacing: 8) {
                TextField("your language, e.g. ru", text: $editor.nativeLanguageDraft)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .nativeLanguage)
                    .onSubmit { editor.confirmNativeLanguage() }
                Button("Save") { editor.confirmNativeLanguage() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        } else if !editor.trimmedTerm.isEmpty {
            HStack(spacing: 18) {
                Button { editor.generateDefinition(mode: .sameLanguage) } label: {
                    Label("Define", systemImage: "character.book.closed")
                }
                Button { editor.translateTapped() } label: {
                    Label("Translate", systemImage: "globe")
                }
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            GrowingTextField(
                placeholder: "Anything that helps — a sentence you met it in",
                text: $editor.notes,
                font: .callout,
                minHeight: 56
            )
            .focused($focus, equals: .notes)
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - Tags

    private var tagsSection: some View {
        Section("Tags") {
            if !editor.tags.isEmpty {
                FlowLayout {
                    ForEach(editor.tags, id: \.self) { name in
                        RemovableTagChip(name: name, color: colour(of: name)) {
                            editor.remove(tag: name)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .font(.footnote)
                    .foregroundStyle(Theme.textFaint)
                TextField("Add a tag", text: $tagDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .tag)
                    .onSubmit(commitTagDraft)
                if !tagDraft.isEmpty {
                    Button("Add", action: commitTagDraft)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }

            if !suggestions.isEmpty {
                FlowLayout {
                    ForEach(suggestions) { tag in
                        TagChip(name: tag.name, color: tag.color) {
                            editor.toggle(tag.name)
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listRowBackground(Theme.surface)
    }

    /// The tags this card does not carry yet, most-used first — and narrowed by
    /// whatever is being typed, so a collection with thirty tags still offers
    /// the right one in a tap.
    private var suggestions: [Tag] {
        let draft = tagDraft.trimmingCharacters(in: .whitespaces).lowercased()
        return tagStore.byUse.filter { tag in
            guard !editor.tags.contains(tag.name) else { return false }
            return draft.isEmpty || tag.name.lowercased().contains(draft)
        }
    }

    private func colour(of name: String) -> String? {
        tagStore.tags.first { $0.name == name }?.color
    }

    /// A name typed rather than picked. The server creates a tag on first use —
    /// `resolve_tags` does it on the card endpoints — so this is not an error
    /// case, it is how a tag gets made from here.
    private func commitTagDraft() {
        editor.add(tag: tagDraft)
        tagDraft = ""
        focus = .tag
    }

    // MARK: - Grade and rotation

    private var gradeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your grade")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                StarRatingPicker(rating: $editor.starRating)
            }
            .padding(.vertical, 2)

            Toggle(isOn: $editor.suspended) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paused")
                    Text("Kept, but never asked.")
                        .font(.caption)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .tint(Theme.accent)
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - Audio

    /// Read-only, deliberately. Recording a clip is a screen of its own and the
    /// clips that exist were made by the server's TTS or uploaded from a desk;
    /// what a phone wants is to hear one.
    @ViewBuilder private func audioSection(_ card: Card) -> some View {
        let clips = card.audioClips ?? []
        if !clips.isEmpty {
            Section("Audio") {
                ForEach(clips) { clip in
                    Button {
                        audio.play(clip, using: session)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: audio.playingClipID == clip.id ? "speaker.wave.2.fill" : "play.circle")
                                .foregroundStyle(Theme.accent)
                            Text(clip.side == .term ? "Term" : "Meaning")
                                .foregroundStyle(Theme.text)
                            Spacer()
                            if let ms = clip.durationMs {
                                Text(String(format: "%.1fs", Double(ms) / 1000))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }
            }
            .listRowBackground(Theme.surface)
        }
    }

    // MARK: - What the scheduler knows

    private func factsSection(_ card: Card) -> some View {
        Section("History") {
            switch card.timesShown {
            case 0: fact("Seen", "not yet")
            case 1: fact("Seen", "once")
            default: fact("Seen", "\(card.timesShown)×")
            }
            if let accuracy = card.accuracy {
                fact("Correct", "\(Int((accuracy * 100).rounded()))%")
            }
            if card.lapses > 0 {
                fact("Forgotten", "\(card.lapses)×", tint: Theme.hard)
            }
            fact("Due", card.dueAt.relative, tint: card.dueAt <= Date() ? Theme.accent : Theme.textMuted)
            if let last = card.lastReviewAt {
                fact("Last answered", last.relative)
            } else {
                fact("Last answered", "never — this one is new")
            }
        }
        .listRowBackground(Theme.surface)
    }

    private func fact(_ label: String, _ value: String, tint: Color = Theme.textMuted) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - Delete

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                if editor.isDeleting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Delete card")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(editor.isDeleting)
        } footer: {
            if let notice = editor.notice {
                NoticeLine(text: notice)
            } else {
                // Says what survives, not just what goes: a delete that reads as
                // final is a delete nobody makes, and this one is not.
                Text("The card is kept as a tombstone so your other devices learn about it, and the Cards list offers it back for a few seconds.")
            }
        }
        .listRowBackground(Theme.surface)
        .confirmationDialog(
            editor.original.map { "Delete “\($0.term)”?" } ?? "Delete this card?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Keep it", role: .cancel) {}
        }
    }

    // MARK: - Actions

    private func save() {
        Task {
            guard let card = await editor.save() else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFinish(.saved(card))
            dismiss()
        }
    }

    private func delete() {
        guard let id = editor.original?.id else { return }
        Task {
            guard await editor.delete() else { return }
            onFinish(.deleted(id))
            dismiss()
        }
    }
}
