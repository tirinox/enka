import SwiftUI
import UIKit

/// Quick capture, the phone's copy of the Mac's Add tab.
///
/// One field that matters and one that can wait. The API allows a card with no
/// definition, and that is the intended shape of this screen: you met a word,
/// you have three seconds, type it and move on. The meaning gets filled in
/// later — at a desk, or right here with one AI-generated suggestion when three
/// seconds is also enough to check it.
///
/// The duplicate warning under the field is why this screen talks to the search
/// endpoint at all. Half of adding a word is finding out you added it in March.
struct AddView: View {
    @EnvironmentObject private var capture: CaptureStore
    @EnvironmentObject private var tagStore: TagStore
    @EnvironmentObject private var library: LibraryStore

    @FocusState private var focus: Field?
    private enum Field: Hashable { case term, definition, nativeLanguage }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    termField
                    status
                    aiRow
                    definitionField
                    tagPicker
                    saveButton
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .navigationTitle("Add a word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if focus != nil {
                        Button("Done") { focus = nil }
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .onChange(of: capture.term) { _, _ in capture.lookupChanged() }
        .onChange(of: capture.askingNativeLanguage) { _, asking in
            if asking { focus = .nativeLanguage }
        }
        // The card list is one tab away and was fetched before this word
        // existed. Handing it the card is cheaper than a refetch and keeps the
        // scroll position of whoever is going back and forth.
        .onChange(of: capture.lastCreated) { _, card in
            if let card { library.insert(card) }
        }
        .animation(Theme.normal, value: capture.duplicate?.id)
        .animation(Theme.normal, value: capture.justSaved)
        .animation(Theme.normal, value: capture.isGenerating)
    }

    // MARK: - The two fields

    private var termField: some View {
        HStack(spacing: 10) {
            TextField("New word", text: $capture.term)
                .font(.system(.title2, design: .serif).weight(.medium))
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .term)
                .onSubmit { focus = .definition }

            if capture.isSaving {
                ProgressView()
            } else if capture.justSaved != nil {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.good)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                .strokeBorder(capture.duplicate == nil ? Theme.border : Theme.accentBorder, lineWidth: 1)
        )
    }

    private var definitionField: some View {
        GrowingTextField(
            placeholder: "Meaning — optional, it can wait",
            text: $capture.definition,
            minHeight: 96
        )
        .focused($focus, equals: .definition)
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    // MARK: - What the collection already knows

    @ViewBuilder private var status: some View {
        if let notice = capture.notice {
            NoticeLine(text: notice)
        } else if let saved = capture.justSaved {
            NoticeLine(text: "Added \(saved)", symbol: "checkmark.circle.fill", tint: Theme.success)
        } else if let duplicate = capture.duplicate {
            NoticeLine(
                text: duplicate.definition.map { "Already here — \($0)" } ?? "Already here, with no meaning yet",
                symbol: "exclamationmark.circle.fill",
                tint: Theme.accent
            )
        } else if !capture.nearby.isEmpty {
            HStack(spacing: 6) {
                Text("close:")
                    .font(.footnote)
                    .foregroundStyle(Theme.textFaint)
                ForEach(capture.nearby) { card in
                    Text(card.term)
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Theme.surfaceActive, in: .capsule)
                }
            }
        }
    }

    // MARK: - AI definition

    @ViewBuilder private var aiRow: some View {
        if capture.isGenerating {
            HStack(spacing: 8) {
                ProgressView()
                Text("Thinking…")
                    .font(.footnote)
                    .foregroundStyle(Theme.textFaint)
            }
        } else if capture.askingNativeLanguage {
            HStack(spacing: 8) {
                TextField("your language, e.g. ru", text: $capture.nativeLanguageDraft)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .nativeLanguage)
                    .onSubmit { capture.confirmNativeLanguage() }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.radiusSmall))
                Button("Save") { capture.confirmNativeLanguage() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        } else if !capture.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 18) {
                Button { capture.generateDefinition(mode: .sameLanguage) } label: {
                    Label("Define", systemImage: "character.book.closed")
                }
                Button { capture.translateTapped() } label: {
                    Label("Translate", systemImage: "globe")
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.accent)
        }
    }

    // MARK: - Tags

    @ViewBuilder private var tagPicker: some View {
        if !tagStore.tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Tags")
                FlowLayout {
                    ForEach(tagStore.byUse) { tag in
                        TagChip(
                            name: tag.name,
                            color: tag.color,
                            selected: capture.selectedTags.contains(tag.name)
                        ) {
                            if capture.selectedTags.contains(tag.name) {
                                capture.selectedTags.remove(tag.name)
                            } else {
                                capture.selectedTags.insert(tag.name)
                            }
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Saving

    private var saveButton: some View {
        Button(action: save) {
            Text("Add card")
        }
        .buttonStyle(AccentButtonStyle())
        .disabled(!capture.canSave)
        .padding(.top, 2)
    }

    /// Saves, then clears and stays put — the screen is for adding words,
    /// plural. The keyboard stays up for the same reason: it is the difference
    /// between adding one word and adding the four you met in a paragraph.
    private func save() {
        guard capture.canSave else { return }
        capture.save()
        focus = .term
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
