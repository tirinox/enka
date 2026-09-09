import SwiftUI
import UIKit

/// The collection, and the one screen in Enka that changes it.
///
/// The Mac's Search tab is read-mostly on purpose — a panel that unfolds on a
/// hover is four seconds of somebody's attention, and "look here, edit in the
/// web client" was the right trade for it. A phone is the other case: it is
/// where a collection gets tidied, on a sofa, a card at a time. So this list
/// opens the whole card, not a summary of it.
///
/// Empty, the field browses — newest first, a page at a time. Typed into, it
/// searches, and the search is the trigram one: `cafe` finds `café` and
/// `fenstr` finds `das Fenster`. Half-remembering a word is the normal way of
/// looking for it.
struct CardsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tagStore: TagStore
    @EnvironmentObject private var audio: AudioPlayback

    @State private var editing: Card?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !tagStore.tags.isEmpty { filterRow }
                content
            }
            .background(Theme.bg)
            .navigationTitle("Cards")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $library.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Find a card — typos are fine"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        TagsView()
                    } label: {
                        Image(systemName: "tag")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            // A safe-area inset rather than an overlay: the tab bar floats over
            // the bottom of the content, and an overlay pinned to `.bottom`
            // lands underneath it, where it is a bar nobody ever sees.
            .safeAreaInset(edge: .bottom, spacing: 0) { undoBar }
        }
        .tint(Theme.accent)
        .task { library.loadIfNeeded() }
        .onChange(of: library.query) { _, _ in library.queryChanged() }
        .sheet(item: $editing) { card in
            CardEditorView(session: session, card: card, tags: tagStore, audio: audio) { outcome in
                switch outcome {
                case let .saved(card): library.apply(card)
                case let .deleted(id): library.remove(id: id)
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            CardEditorView(session: session, card: nil, tags: tagStore, audio: audio) { outcome in
                if case let .saved(card) = outcome { library.insert(card) }
            }
        }
    }

    // MARK: - Filtering

    /// One tag at a time. A phone has room for a row of chips and no room for
    /// the "any of these / all of these" question a second one would raise.
    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                TagChip(name: "All", color: nil, selected: library.tagFilter == nil) {
                    library.tagFilter = nil
                }
                ForEach(tagStore.byUse) { tag in
                    TagChip(name: tag.name, color: tag.color, selected: library.tagFilter == tag.name) {
                        library.tagFilter = library.tagFilter == tag.name ? nil : tag.name
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.bg)
    }

    // MARK: - The list

    @ViewBuilder private var content: some View {
        if library.cards.isEmpty {
            if library.isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let notice = library.notice {
                EmptyNotice(
                    symbol: "exclamationmark.triangle",
                    message: notice,
                    tint: Theme.danger,
                    action: ("Try again", { library.refresh() })
                )
            } else if library.isSearching {
                EmptyNotice(symbol: "questionmark.circle", message: "Nothing like that in the collection.")
            } else if library.tagFilter != nil {
                EmptyNotice(symbol: "tag", message: "No cards carry that tag yet.")
            } else {
                EmptyNotice(
                    symbol: "square.stack",
                    message: "No cards yet.\nThe Add tab is one word and a return.",
                    action: ("Add one", { isCreating = true })
                )
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if let notice = library.notice {
                NoticeLine(text: notice)
                    .listRowBackground(Theme.bg)
                    .listRowSeparator(.hidden)
            }

            ForEach(library.cards) { card in
                CardRow(
                    card: card,
                    playing: audio.playingClipID.map { id in card.audioClips?.contains { $0.id == id } ?? false } ?? false,
                    play: { audio.playAll(card.clips(for: .term) + card.clips(for: .definition), using: session) }
                )
                .contentShape(Rectangle())
                .onTapGesture { editing = card }
                .listRowBackground(Theme.bgElevated)
                .swipeActions(edge: .leading) {
                    Button {
                        library.toggleSuspended(card)
                    } label: {
                        Label(card.suspended ? "Resume" : "Pause", systemImage: card.suspended ? "play" : "pause")
                    }
                    .tint(Theme.hard)
                }
                .swipeActions(edge: .trailing) {
                    // No confirmation: the delete is soft, the undo below is
                    // real — `POST /cards/{id}/restore` — and a dialog in front
                    // of something that reversible is friction bought for
                    // nothing.
                    Button(role: .destructive) {
                        library.delete(card)
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .onAppear {
                    if card.id == library.cards.last?.id { library.loadMore() }
                }
            }

            footer
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await library.reload() }
        .animation(Theme.normal, value: library.cards)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            if library.isLoadingMore {
                ProgressView()
            } else if library.isSearching {
                Text(library.exactMatch
                     ? "\(library.cards.count) found — you already have this word."
                     : "\(library.cards.count) found")
            } else if library.canLoadMore {
                Text("\(library.cards.count) of \(library.total)")
            } else if library.total > 0 {
                Text(library.total == 1 ? "1 card" : "\(library.total) cards")
            }
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(Theme.textFaint)
        .padding(.vertical, 8)
    }

    // MARK: - Undo

    /// The deleted card, offered back for a few seconds. Soft deletes are what
    /// make this honest: the row is still on the server, tombstoned, until
    /// something purges it.
    @ViewBuilder private var undoBar: some View {
        if let deleted = library.lastDeleted {
            HStack(spacing: 12) {
                Text("Deleted “\(deleted.term)”")
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Undo") { library.undoDelete() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.radiusLarge))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(Theme.normal, value: library.lastDeleted)
        }
    }
}

// MARK: - One row

/// Collapsed to two lines and a corner. Everything else a card carries — the
/// notes, the counts, the tags, the audio — is one tap away in the editor,
/// because a list that shows everything shows four cards a screen.
private struct CardRow: View {
    let card: Card
    let playing: Bool
    let play: () -> Void

    private var hasAudio: Bool { !(card.audioClips ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.term)
                    .font(.system(.body, design: .serif).weight(.medium))
                    .foregroundStyle(card.suspended ? Theme.textFaint : Theme.text)
                    .lineLimit(1)

                if let stars = card.starRating, stars > 0 {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.hard)
                }

                Spacer(minLength: 4)

                if card.suspended {
                    Text("paused")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.hard)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Theme.hard.opacity(0.14), in: .capsule)
                } else {
                    Text(card.dueAt.relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(card.dueAt <= Date() ? Theme.accent : Theme.textFaint)
                }

                if hasAudio {
                    Button(action: play) {
                        Image(systemName: playing ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.footnote)
                            .foregroundStyle(playing ? Theme.accent : Theme.textFaint)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                if let definition = card.definition, !definition.isEmpty {
                    Text(definition)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                } else {
                    // The count this app exists to bring down: a word captured
                    // on the run, meaning still to come.
                    Text("no meaning yet")
                        .font(.subheadline.italic())
                        .foregroundStyle(Theme.textFaint)
                }

                Spacer(minLength: 4)

                ForEach(card.tags.prefix(2), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Theme.surfaceActive, in: .capsule)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
