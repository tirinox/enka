import SwiftUI

/// "Do I have this word, and what did I write for it?"
///
/// The search endpoint is a trigram search that ignores case and accents, so
/// `cafe` finds `café` and `fenstr` finds `das Fenster`. That tolerance is the
/// reason this tab is worth a panel: you half-remember a word, and half is
/// enough.
struct SearchPane: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var search: SearchStore
    @ObservedObject private var audio: AudioPlayback

    @FocusState private var focused: Bool

    init(vm: NotchViewModel) {
        self.vm = vm
        self.search = vm.search
        self.audio = vm.audio
    }

    var body: some View {
        VStack(spacing: 8) {
            field
            results
        }
        .onAppear { focused = true }
        .onChange(of: vm.wantsKeyboard) { _, wants in focused = wants }
        .onChange(of: search.query) { _, _ in search.queryChanged() }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            TextField("", text: $search.query, prompt: Text("Find a card").foregroundColor(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .tint(Theme.secondary)
                .focused($focused)
            if search.isSearching {
                ProgressView().controlSize(.small)
            } else if !search.query.isEmpty {
                Button { search.clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
    }

    @ViewBuilder
    private var results: some View {
        if let notice = search.notice {
            centred(notice, symbol: "exclamationmark.triangle", tint: Theme.again)
        } else if search.query.trimmingCharacters(in: .whitespaces).count < 2 {
            centred("Two letters is enough — typos and accents are fine.", symbol: "text.magnifyingglass")
        } else if search.hits.isEmpty && !search.isSearching {
            centred("Nothing like that in the collection.", symbol: "questionmark.circle")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(search.hits) { hit in
                        ResultRow(
                            hit: hit,
                            expanded: search.expanded == hit.card.id,
                            play: { clips in audio.playAll(clips, using: vm.session) },
                            playingClipID: audio.playingClipID,
                            toggleExpanded: {
                                search.expanded = search.expanded == hit.card.id ? nil : hit.card.id
                            },
                            toggleSuspended: { search.toggleSuspended(hit.card) },
                            isGenerating: search.isGenerating,
                            suggestion: search.suggestion,
                            askingNativeLanguage: search.askingNativeLanguage,
                            nativeLanguageDraft: $search.nativeLanguageDraft,
                            define: { search.generateDefinition(for: hit.card, mode: .sameLanguage) },
                            translate: { search.translateTapped(for: hit.card) },
                            confirmNativeLanguage: { search.confirmNativeLanguage(for: hit.card) },
                            acceptSuggestion: { search.acceptSuggestion(for: hit.card) },
                            discardSuggestion: { search.discardSuggestion() }
                        )
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func centred(_ text: String, symbol: String, tint: Color = Theme.tertiary) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
            Text(text)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One hit. Collapsed it is a line; expanded it is the same line with the
/// bookkeeping underneath — how often it has been seen, how often forgotten,
/// when it is next due.
private struct ResultRow: View {
    let hit: SearchHit
    let expanded: Bool
    let play: ([AudioClip]) -> Void
    let playingClipID: String?
    let toggleExpanded: () -> Void
    let toggleSuspended: () -> Void
    let isGenerating: Bool
    let suggestion: String?
    let askingNativeLanguage: Bool
    let nativeLanguageDraft: Binding<String>
    let define: () -> Void
    let translate: () -> Void
    let confirmNativeLanguage: () -> Void
    let acceptSuggestion: () -> Void
    let discardSuggestion: () -> Void

    @State private var hovering = false

    private var card: Card { hit.card }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Text(card.term)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundStyle(card.suspended ? Theme.tertiary : Theme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let definition = card.definition, !definition.isEmpty {
                    Text(definition)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                } else {
                    Text("no definition")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .italic()
                }

                Spacer(minLength: 6)

                if card.suspended {
                    Chip(text: "suspended", tint: Theme.hard)
                }

                if hovering || expanded {
                    let clips = card.audioClips ?? []
                    if !clips.isEmpty {
                        Button { play(clips) } label: {
                            Image(systemName: clips.contains(where: { $0.id == playingClipID })
                                  ? "speaker.wave.2.fill" : "speaker.wave.2")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Play")
                    }
                    Button(action: toggleSuspended) {
                        Image(systemName: card.suspended ? "play.circle" : "pause.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(card.suspended ? "Put it back in rotation" : "Suspend — stop showing it")
                } else {
                    Text(card.dueAt.relative)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(height: 26)

            if expanded {
                detail
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, expanded ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering || expanded ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggleExpanded)
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: expanded)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 5) {
            aiSection
            if let notes = card.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Stat(label: "seen", value: "\(card.timesShown)")
                if let accuracy = card.accuracy {
                    Stat(label: "correct", value: "\(Int((accuracy * 100).rounded()))%")
                }
                if card.lapses > 0 {
                    Stat(label: "forgotten", value: "\(card.lapses)", tint: Theme.hard)
                }
                Stat(label: "due", value: card.dueAt.relative)
                Spacer(minLength: 0)
                ForEach(card.tags.prefix(3), id: \.self) { tag in
                    Chip(text: tag)
                }
            }
        }
        .padding(.bottom, 2)
    }

    /// One of four states: idle (two small actions), thinking, a suggestion
    /// waiting on accept/discard, or — the one time this row asks for text —
    /// a native-language prompt. Accept/discard only: free-text editing of
    /// the suggestion is the web client's job, not this panel's.
    @ViewBuilder
    private var aiSection: some View {
        if isGenerating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Thinking…")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
        } else if let suggestion {
            HStack(spacing: 6) {
                Text(suggestion)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(action: acceptSuggestion) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.good)
                }
                .buttonStyle(.plain)
                .help("Save this definition")
                Button(action: discardSuggestion) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
                .help("Discard")
            }
        } else if askingNativeLanguage {
            HStack(spacing: 6) {
                TextField(
                    "", text: nativeLanguageDraft,
                    prompt: Text("e.g. ru").foregroundColor(Theme.tertiary)
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surface))
                .onSubmit(confirmNativeLanguage)
                Button("Save", action: confirmNativeLanguage)
                    .buttonStyle(PanelButtonStyle())
            }
        } else {
            HStack(spacing: 12) {
                Button(action: define) {
                    Label("Define", systemImage: "character.book.closed")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("AI-generate a definition")

                Button(action: translate) {
                    Label("Translate", systemImage: "globe")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("AI-translate into your native language")
            }
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var tint: Color = Theme.secondary

    var body: some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
    }
}
