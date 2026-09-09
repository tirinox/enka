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
///
/// The word is usually on the clipboard before this screen is opened at all —
/// you were reading something and you selected it — so the field takes what is
/// there rather than asking for it to be typed a second time. See `offerClipboard`.
struct AddView: View {
    @EnvironmentObject private var capture: CaptureStore
    @EnvironmentObject private var tagStore: TagStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase

    @FocusState private var focus: Field?
    private enum Field: Hashable { case term, definition, nativeLanguage }

    /// Whether there is anything to paste. `hasStrings` answers that without
    /// reading, which is what keeps the button out of the way when the
    /// clipboard is empty and keeps iOS's paste question tied to a press.
    @State private var clipboardHasText = false
    /// The clipboard generation already offered, so a tab switched away from
    /// and back to does not ask about the same word twice — and neither does a
    /// refusal get asked about again.
    @State private var offeredChangeCount = -1
    /// Said once, quietly, when the field filled itself: text appearing in a
    /// field nobody typed into needs a sentence explaining where it came from.
    @State private var clipboardNote: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    termField
                    clipboardLine
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
        .onAppear { offerClipboard() }
        // Coming back from wherever the word was copied is the case this is
        // for: Safari, a message, a dictionary app. The tab was already on
        // screen, so `onAppear` will not fire again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { offerClipboard() }
        }
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
            } else if !capture.term.isEmpty {
                // The phone's Escape. The Mac empties this field with a key
                // and a phone has none, so a word typed or pasted by mistake
                // had no way out but the backspace key, held down.
                Button {
                    capture.clear()
                    clipboardNote = nil
                    focus = .term
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            } else if clipboardHasText {
                pasteButton
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

    /// The system's own paste control rather than a button of ours.
    ///
    /// It looks the same in every app, and — the reason it is here — a press on
    /// it *is* the permission, so it hands the text over without the "Allow
    /// Paste?" question that reading the clipboard from code has to ask. The
    /// automatic fill below has no such button behind it and so does ask; this
    /// is the path for anybody who turned that off, and for a second word
    /// copied while this screen was already open.
    private var pasteButton: some View {
        PasteButton(payloadType: String.self) { items in
            guard let text = items.first else { return }
            apply(PastedCard.parse(text), automatic: false)
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.capsule)
    }

    /// Where the words in the field came from, when nobody put them there.
    /// Its own line rather than the status row below, which belongs to what the
    /// collection has to say about the word and should not be pushed aside for
    /// three seconds by a note about the clipboard.
    @ViewBuilder private var clipboardLine: some View {
        if let clipboardNote {
            Label(clipboardNote, systemImage: "doc.on.clipboard")
                .font(.footnote)
                .foregroundStyle(Theme.textFaint)
                .transition(.opacity)
        }
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
        clipboardNote = nil
        focus = .term
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - The clipboard

    /// Asks the system for what was last copied, and puts it in the field.
    ///
    /// This is the gesture the screen exists to save. The word is on the
    /// clipboard before the app is even open — you were reading something and
    /// you selected it — so typing it again is typing something the phone
    /// already has.
    ///
    /// iOS asks the user before handing it over, which is why this is guarded
    /// rather than run on every appearance. Once per copy: the change count
    /// moves only when something new is copied, so a tab left and come back to
    /// does not ask twice, and neither does a refusal get argued with. Never
    /// over anything already on screen, because a half-typed word is worth more
    /// than whatever is on the clipboard — somebody is in the middle of it.
    private func offerClipboard() {
        let pasteboard = UIPasteboard.general
        clipboardHasText = pasteboard.hasStrings

        guard Preferences.fillFromClipboard, pasteboard.hasStrings else { return }
        guard pasteboard.changeCount != offeredChangeCount else { return }
        offeredChangeCount = pasteboard.changeCount
        guard capture.term.isEmpty, capture.definition.isEmpty else { return }
        guard let text = pasteboard.string,
              let card = PastedCard.parse(text),
              card.looksLikeACard else { return }
        apply(card, automatic: true)
    }

    /// Puts a pasted card in the fields. The meaning only when the paste
    /// carried one and the field is empty: a gloss that arrived with the word
    /// must not land on top of one somebody wrote.
    private func apply(_ card: PastedCard?, automatic: Bool) {
        guard let card else { return }
        capture.term = card.term
        let split = card.definition.map { meaning -> Bool in
            guard capture.definition.isEmpty else { return false }
            capture.definition = meaning
            return true
        } ?? false

        if !automatic { UISelectionFeedbackGenerator().selectionChanged() }
        // A press explains itself; text that appears in a field nobody touched
        // does not. The exception is a paste that filled *both* fields, which
        // is worth a word either way because only one of them was aimed at.
        if automatic {
            announce(split ? "From the clipboard — word and meaning." : "From the clipboard.")
        } else if split {
            announce("Split into word and meaning.")
        }
    }

    private func announce(_ message: String) {
        withAnimation(Theme.normal) { clipboardNote = message }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard clipboardNote == message else { return }
            withAnimation(Theme.normal) { clipboardNote = nil }
        }
    }
}
