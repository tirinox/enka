import SwiftUI

/// The one tab that edits the collection.
///
/// Tags are the exception to "look here, edit in the web client", and they earn
/// it: a tag is a word and a colour, the whole of it fits on one row, and the
/// moment you want a new one is the moment you are adding the card that needs
/// it — which is one tab to the left.
///
/// Deleting is here too, and it is the only destructive thing in the panel. It
/// asks first, in the row itself rather than in a dialog, and it says what it
/// will and will not touch: the label goes, the cards stay.
struct TagsPane: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var store: TagStore

    @State private var draftName = ""
    @State private var draftColor: String?
    @State private var isCreating = false
    @FocusState private var focus: TagsPaneFocus?

    init(vm: NotchViewModel) {
        self.vm = vm
        self.store = vm.tagStore
    }

    var body: some View {
        VStack(spacing: 8) {
            newTagRow
            list
            if let notice = store.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.again)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { focus = .new }
        .onChange(of: vm.wantsKeyboard) { _, wants in
            if wants, focus == nil { focus = .new }
            if !wants { focus = nil }
        }
        // A row that opens for editing takes the caret with it; closing gives it
        // back to the field at the top, which is where the next thing typed
        // almost certainly belongs.
        .onChange(of: store.editing) { _, editing in
            focus = editing.map(TagsPaneFocus.row) ?? .new
        }
        .animation(Theme.contentAnimation, value: store.editing)
        .animation(Theme.contentAnimation, value: store.confirmingDelete)
        .animation(Theme.contentAnimation, value: store.notice)
    }

    // MARK: - New

    private var newTagRow: some View {
        HStack(spacing: 8) {
            ColourDot(hex: draftColor, diameter: 10)

            TextField("", text: $draftName, prompt: Text("New tag").foregroundColor(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .tint(Theme.secondary)
                .focused($focus, equals: .new)
                .onSubmit { create() }

            Palette(selected: $draftColor)

            Button(action: create) {
                Text(isCreating ? "…" : "Add")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canCreate ? Theme.ink : Theme.tertiary)
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(canCreate ? Theme.accent.opacity(0.9) : Theme.surface)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private var canCreate: Bool {
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        let name = draftName
        let colour = draftColor
        Task {
            if await store.create(name: name, color: colour) {
                draftName = ""
                draftColor = nil
                focus = .new
            }
            isCreating = false
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if store.tags.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tag")
                    .font(.system(size: 20, weight: .light))
                Text(store.isLoading ? "Loading…" : "No tags yet. The field above makes one.")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(store.byUse) { tag in
                        TagRow(
                            tag: tag,
                            store: store,
                            focus: $focus
                        )
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}

/// One tag, in whichever of its three states it is in: showing, being renamed,
/// or being asked about before it goes.
private struct TagRow: View {
    let tag: Tag
    @ObservedObject var store: TagStore
    @FocusState.Binding var focus: TagsPaneFocus?

    @State private var draftName = ""
    @State private var draftColor: String?
    @State private var hovering = false

    private var isEditing: Bool { store.editing == tag.id }
    private var isConfirming: Bool { store.confirmingDelete == tag.id }
    private var isBusy: Bool { store.busy.contains(tag.id) }

    var body: some View {
        Group {
            if isConfirming {
                confirming
            } else if isEditing {
                editing
            } else {
                resting
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isConfirming ? Theme.again.opacity(0.12)
                      : (hovering || isEditing ? Theme.surfaceHover : Theme.surface))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Seeded on the transition rather than by whatever opened the row.
        // The pencil is not the only way in — Escape closes a row, the store
        // closes them all on the way out of the tab — and a row that opened
        // with an empty draft would offer to rename the tag to nothing.
        .onChange(of: isEditing) { _, editing in
            guard editing else { return }
            draftName = tag.name
            draftColor = tag.color
        }
    }

    // MARK: - Resting

    private var resting: some View {
        HStack(spacing: 9) {
            ColourDot(hex: tag.color, diameter: 9)
            Text(tag.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 6)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if hovering {
                Button {
                    store.confirmingDelete = nil
                    store.editing = tag.id
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Rename or recolour")

                Button {
                    store.editing = nil
                    store.confirmingDelete = tag.id
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete this tag")
            } else {
                Text(count)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .onTapGesture {
            store.confirmingDelete = nil
            store.editing = tag.id
        }
    }

    private var count: String {
        let value = tag.cardCount ?? 0
        return value == 1 ? "1 card" : "\(value) cards"
    }

    // MARK: - Editing

    private var editing: some View {
        HStack(spacing: 8) {
            ColourDot(hex: draftColor, diameter: 9)
            TextField("", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .tint(Theme.secondary)
                .focused($focus, equals: .row(tag.id))
                .onSubmit { save() }

            Palette(selected: $draftColor)

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(action: save) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.good)
                }
                .buttonStyle(.plain)
                .help("Save  (return)")

                Button { store.editing = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Discard  (esc)")
            }
        }
    }

    private func save() {
        // A double optional: `nil` means "leave the colour alone", and
        // `.some(nil)` means "clear it". The palette produces both, and the
        // difference has to survive all the way to the PATCH body.
        let colour: String?? = draftColor == tag.color ? nil : .some(draftColor)
        let name = draftName
        Task { await store.rename(tag, to: name, color: colour) }
    }

    // MARK: - Confirming

    private var confirming: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.again)
            // Says what survives, not just what goes. "Delete tag?" leaves the
            // reader to guess whether the cards go with it, and the guess that
            // stops somebody deleting a tag they wanted gone is the wrong one.
            Text("Delete “\(tag.name)”? The cards keep everything else.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button("Cancel") { store.confirmingDelete = nil }
                    .buttonStyle(PanelButtonStyle())
                Button {
                    Task { await store.delete(tag) }
                } label: {
                    Text("Delete")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.again.opacity(0.85))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Eight swatches and an off switch. Pressing the one already chosen clears the
/// colour, which is the only way back to "no colour" and the same gesture the
/// web client uses for it.
private struct Palette: View {
    @Binding var selected: String?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TagStore.palette, id: \.self) { hex in
                Button {
                    selected = selected == hex ? nil : hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex) ?? Theme.tertiary)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Theme.ink, lineWidth: selected == hex ? 1.5 : 0)
                                .padding(-2)
                        )
                        .contentShape(Circle().inset(by: -2))
                }
                .buttonStyle(.plain)
                .help(selected == hex ? "Clear the colour" : "Use \(hex)")
            }
        }
    }
}

private struct ColourDot: View {
    let hex: String?
    let diameter: CGFloat

    var body: some View {
        Group {
            if let hex, let colour = Color(hex: hex) {
                Circle().fill(colour)
            } else {
                // A ring rather than a grey disc: "no colour chosen" and "the
                // colour is grey" are different things, and #8a8f98 is in the
                // palette.
                Circle().stroke(Theme.tertiary, lineWidth: 1)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Which field holds the caret. Declared at file scope rather than inside
/// `TagsPane` because the rows bind to the same `@FocusState`, and a nested
/// type would make the binding's type unspellable from there.
enum TagsPaneFocus: Hashable {
    case new
    case row(String)
}
