import SwiftUI

/// The tag list, and the four things one does to it.
///
/// A tag is a word and a colour: the whole of it fits on one row, which is why
/// the Mac lets its panel edit them and edits nothing else. Here it is a pushed
/// screen rather than a tab, reached from the cards it labels and from the
/// settings, because it is opened a few times a month and a fifth of the bottom
/// bar is worth more than that.
///
/// Deleting says what it will and will not touch, in the row rather than in a
/// dialog: the label goes, the cards keep everything else.
struct TagsView: View {
    @EnvironmentObject private var store: TagStore
    @EnvironmentObject private var library: LibraryStore

    @State private var draftName = ""
    @State private var draftColor: String?
    @State private var isCreating = false
    @State private var editing: Tag?
    @FocusState private var newTagFocused: Bool

    var body: some View {
        List {
            newTagSection

            if store.tags.isEmpty {
                Section {
                    if store.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("No tags yet. The field above makes one.")
                            .font(.callout)
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                .listRowBackground(Theme.surface)
            } else {
                Section {
                    ForEach(store.byUse) { tag in
                        row(tag)
                    }
                } header: {
                    Text("Most used first")
                } footer: {
                    if let notice = store.notice {
                        NoticeLine(text: notice)
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reload() }
        .task { store.refresh() }
        .tint(Theme.accent)
        .sheet(item: $editing) { tag in
            TagSheet(tag: tag, store: store)
        }
        .animation(Theme.normal, value: store.tags)
    }

    // MARK: - New

    private var newTagSection: some View {
        Section("New tag") {
            HStack(spacing: 10) {
                ColourDot(hex: draftColor)
                TextField("Name", text: $draftName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($newTagFocused)
                    .onSubmit(create)
                if isCreating {
                    ProgressView()
                } else {
                    Button("Add", action: create)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(canCreate ? Theme.accent : Theme.textFaint)
                        .disabled(!canCreate)
                }
            }
            PalettePicker(selected: $draftColor)
                .padding(.vertical, 2)
        }
        .listRowBackground(Theme.surface)
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
                newTagFocused = true
            }
            isCreating = false
        }
    }

    // MARK: - One tag

    private func row(_ tag: Tag) -> some View {
        HStack(spacing: 12) {
            ColourDot(hex: tag.color)
            Text(tag.name)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if store.busy.contains(tag.id) {
                ProgressView()
            } else {
                Text(count(tag))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = tag }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.confirmingDelete = tag.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete “\(tag.name)”?",
            isPresented: Binding(
                get: { store.confirmingDelete == tag.id },
                set: { if !$0, store.confirmingDelete == tag.id { store.confirmingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete the tag", role: .destructive) {
                Task {
                    await store.delete(tag)
                    library.reconcile(with: store.tags)
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The cards keep everything else — only the label goes.")
        }
    }

    private func count(_ tag: Tag) -> String {
        let value = tag.cardCount ?? 0
        return value == 1 ? "1 card" : "\(value) cards"
    }
}

/// Rename and recolour, in a sheet rather than in the row.
///
/// The Mac edits in place because its rows are 30 points tall and a sheet over
/// a panel that lives in the notch would be absurd. A phone row is a thumb
/// wide, and putting a text field, eight swatches and two buttons inside one
/// would leave nothing hittable.
private struct TagSheet: View {
    let tag: Tag
    @ObservedObject var store: TagStore

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colour: String?
    @FocusState private var focused: Bool

    init(tag: Tag, store: TagStore) {
        self.tag = tag
        self.store = store
        _name = State(initialValue: tag.name)
        _colour = State(initialValue: tag.color)
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && (trimmed != tag.name || colour != tag.color)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    HStack(spacing: 10) {
                        ColourDot(hex: colour)
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($focused)
                            .onSubmit(save)
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    PalettePicker(selected: $colour)
                        .padding(.vertical, 4)
                } header: {
                    Text("Colour")
                } footer: {
                    Text("Tapping the colour it already has clears it.")
                }
                .listRowBackground(Theme.surface)

                if let notice = store.notice {
                    Section {
                        NoticeLine(text: notice)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Edit tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.busy.contains(tag.id) {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium])
    }

    private func save() {
        guard canSave else { return }
        // A double optional: nil means "leave the colour alone", `.some(nil)`
        // means "clear it". The palette produces both, and the difference has
        // to survive all the way to the PATCH body.
        let change: String?? = colour == tag.color ? nil : .some(colour)
        Task {
            await store.rename(tag, to: name, color: change)
            // The store clears `editing` on success and leaves a notice on
            // failure — a name that collided stays on screen to be fixed.
            if store.notice == nil { dismiss() }
        }
    }
}
