import SwiftUI

/// Quick capture.
///
/// One field that matters and one that can wait. The API allows a card with no
/// definition, and that is the intended shape of this tab: you met a word, you
/// have three seconds, type it and move on. The meaning gets filled in later,
/// at a desk, in the web client.
///
/// Return saves. Not ⌘Return — this is the tab you are in for four seconds, and
/// a modifier on the one action it has is a modifier you press four hundred
/// times a year for nothing.
struct AddPane: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var capture: CaptureStore

    @FocusState private var focus: Field?
    private enum Field { case term, definition }

    init(vm: NotchViewModel) {
        self.vm = vm
        self.capture = vm.capture
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            termField
            status
            definitionField
            footer
        }
        .onAppear { focus = .term }
        .onChange(of: vm.wantsKeyboard) { _, wants in
            if wants, focus == nil { focus = .term }
            if !wants { focus = nil }
        }
        .onChange(of: capture.term) { _, _ in capture.lookupChanged() }
        .animation(Theme.contentAnimation, value: capture.duplicate?.id)
        .animation(Theme.contentAnimation, value: capture.justSaved)
    }

    // MARK: - Fields

    private var termField: some View {
        HStack(spacing: 8) {
            TextField("", text: $capture.term, prompt: Text("New word").foregroundColor(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(Theme.ink)
                // Grey rather than the system accent: the caret has to say
                // where typing lands without being the brightest thing in a
                // panel that is mostly dark and mostly still.
                .tint(Theme.secondary)
                .focused($focus, equals: .term)
                .onSubmit { capture.save() }

            if capture.isSaving {
                ProgressView().controlSize(.small)
            } else if capture.justSaved != nil {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.good)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(capture.duplicate == nil ? Color.clear : Theme.accentBorder, lineWidth: 1)
        )
    }

    private var definitionField: some View {
        // A `TextField(axis: .vertical)` grows to fit its text, and growing
        // means reporting a new intrinsic size, which invalidates layout all
        // the way to the root of the panel — once per wrapped line. An editor
        // takes the rectangle it is given and re-wraps inside it, so a new line
        // costs nothing outside its own bounds.
        ZStack(alignment: .topLeading) {
            if capture.definition.isEmpty {
                Text("Meaning — optional, can wait")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $capture.definition)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .tint(Theme.secondary)
                .focused($focus, equals: .definition)
                // The editor insets its text by a few points of its own; pull
                // that back so the first character lines up with the prompt.
                .padding(.leading, -5)
                // ⌘Return from the definition, because plain Return there is
                // a new line — the field is a paragraph, not a name.
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    capture.save()
                    return .handled
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: - What the collection already knows

    @ViewBuilder
    private var status: some View {
        Group {
            if let notice = capture.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.again)
            } else if let saved = capture.justSaved {
                Label("Added \(saved)", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.good)
            } else if let duplicate = capture.duplicate {
                // The reason this tab talks to the search endpoint at all. Half
                // of adding a word is finding out you added it in March.
                Label(
                    duplicate.definition.map { "Already here — \($0)" } ?? "Already here, with no definition yet",
                    systemImage: "exclamationmark.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            } else if !capture.nearby.isEmpty {
                HStack(spacing: 5) {
                    Text("close:")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                    ForEach(capture.nearby) { card in
                        Chip(text: card.term)
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(height: 18, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if capture.tags.isEmpty {
                Text("No tags yet")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(capture.tags.prefix(12)) { tag in
                            TagToggle(
                                tag: tag,
                                selected: capture.selectedTags.contains(tag.name)
                            ) {
                                if capture.selectedTags.contains(tag.name) {
                                    capture.selectedTags.remove(tag.name)
                                } else {
                                    capture.selectedTags.insert(tag.name)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                KeyCap(label: "return")
                Text("save")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
            Button {
                capture.save()
            } label: {
                Text("Add")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(capture.canSave ? Theme.ink : Theme.tertiary)
                    .padding(.horizontal, 14)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(capture.canSave ? Theme.accent.opacity(0.9) : Theme.surface)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!capture.canSave)
        }
        .frame(height: 24)
    }
}

private struct TagToggle: View {
    let tag: Tag
    let selected: Bool
    let toggle: () -> Void

    /// The colour the web client gave the tag, when it gave it one. Parsed
    /// leniently: a bad value is a tag that looks like the others, which is
    /// exactly what it looked like before somebody typed a colour at all.
    private var tint: Color {
        guard let hex = tag.color, let parsed = Color(hex: hex) else { return Theme.tertiary }
        return parsed
    }

    var body: some View {
        Button(action: toggle) {
            Text(tag.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selected ? Theme.ink : tint)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    Capsule().fill(tint.opacity(selected ? 0.45 : 0.12))
                )
                .overlay(
                    Capsule().stroke(tint.opacity(selected ? 0.7 : 0), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    /// `#RRGGBB`, which is the only shape the tag endpoint stores.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
