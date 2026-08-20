import SwiftUI

/// One card, one question, four answers.
///
/// The pane is built around a single idea: the card should be readable from
/// arm's length, because it is being read out of the corner of an eye while
/// something else compiles. Everything that is not the word — the mode, the
/// tags, the counters — is small, quiet, and along the edges.
struct StudyPane: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var study: StudySession
    @ObservedObject private var audio: AudioPlayback

    init(vm: NotchViewModel) {
        self.vm = vm
        self.study = vm.study
        self.audio = vm.audio
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow
            Spacer(minLength: 0)
            face
            Spacer(minLength: 0)
            bottomRow
        }
        .animation(Theme.revealAnimation, value: study.phase)
        .animation(Theme.contentAnimation, value: study.notice)
    }

    // MARK: - Top

    private var topRow: some View {
        HStack(spacing: 6) {
            // A button that cycles rather than a menu. A pop-up menu opened
            // from a non-activating panel runs its own event loop over a window
            // that is deliberately never key, and there are five modes — which
            // is few enough that the one you want is never more than four
            // presses away, and the tooltip says what each of them does.
            Button {
                study.mode = study.mode.next
            } label: {
                Chip(text: study.mode.title, symbol: "line.3.horizontal.decrease")
            }
            .buttonStyle(.plain)
            .help("\(study.mode.blurb)  Click to change.")

            Button {
                study.direction = study.direction.next
            } label: {
                Chip(text: study.direction.title, symbol: "arrow.left.arrow.right")
            }
            .buttonStyle(.plain)
            .help("Which side is asked first")

            if let card = study.currentCard?.card {
                if card.isNew {
                    Chip(text: "new", tint: Theme.accent)
                }
                ForEach(card.tags.prefix(2), id: \.self) { tag in
                    Chip(text: tag)
                }
                if card.lapses >= 4 {
                    Chip(text: "leech", tint: Theme.hard)
                        .help("Forgotten \(card.lapses) times")
                }
            }

            Spacer(minLength: 0)

            if let clips = audibleClips, !clips.isEmpty {
                Button {
                    audio.playAll(clips, using: vm.session)
                } label: {
                    Image(systemName: audio.playingClipID != nil ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(audio.playingClipID != nil ? Theme.accent : Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Play the audio  (R)")
            }

            // A card is read with the mouse wherever it landed, not kept
            // hovering the panel, so hovering away does not close this tab —
            // see `PointerWatcher.pinned`. This is the way back that gives.
            Button {
                vm.requestClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Close  (esc)")
        }
        .frame(height: 20)
    }

    /// The clips for whichever side is currently showing — the same rule the
    /// store plays by, asked from the other direction.
    private var audibleClips: [AudioClip]? {
        guard let study = study.currentCard else { return nil }
        let side = self.study.visibleSide(of: study, revealed: self.study.isRevealed)
        return study.card.clips(for: side)
    }

    // MARK: - The card

    @ViewBuilder
    private var face: some View {
        switch study.phase {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .card(card, revealed):
            CardFace(study: card, revealed: revealed, interval: study.lastInterval)
                .contentShape(Rectangle())
                .onTapGesture { study.reveal() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.good)
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Button("Try again") { study.reload() }
                    .buttonStyle(PanelButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// "Nothing due" is good news in `due` mode and a filter problem in `new`.
    /// Saying which costs a line and saves a puzzled minute.
    private var emptyMessage: String {
        switch study.mode {
        case .due, .smart: return "Nothing due. Come back later."
        case .new: return "No unseen cards left — add some."
        case .reinforce: return "Nothing to reinforce yet."
        case .random: return "The collection is empty."
        }
    }

    // MARK: - Bottom

    @ViewBuilder
    private var bottomRow: some View {
        if let notice = study.notice {
            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(Theme.again)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 32)
        } else {
            switch study.phase {
            case let .card(_, revealed):
                if revealed {
                    ratings
                } else {
                    revealBar
                }
            case .empty, .failed:
                HStack {
                    Spacer()
                    undoButton
                }
                .frame(height: 32)
            default:
                Color.clear.frame(height: 32)
            }
        }
    }

    private var revealBar: some View {
        HStack(spacing: 8) {
            Button {
                study.reveal()
            } label: {
                HStack(spacing: 7) {
                    Text("Reveal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    KeyCap(label: "space", tint: Theme.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.surface)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)

            undoButton
        }
        .frame(height: 32)
    }

    private var ratings: some View {
        HStack(spacing: 6) {
            ForEach(Rating.allCases) { rating in
                Button {
                    study.answer(rating)
                } label: {
                    RatingLabel(rating: rating)
                }
                .buttonStyle(.plain)
            }
            undoButton
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private var undoButton: some View {
        if study.undoableCard != nil {
            Button {
                study.undo()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium))
                    KeyCap(label: "U")
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.surface)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Undo the last answer")
        }
    }
}

// MARK: - Pieces

/// The card itself: prompt above, answer below once it has been earned.
///
/// Both halves are laid out whether or not the answer is showing, and the
/// answer is faded rather than inserted. Inserting it moves the prompt, and a
/// prompt that jumps upward at the moment of recall pulls the eye away from the
/// exact place the answer is about to appear.
private struct CardFace: View {
    let study: StudyCard
    let revealed: Bool
    let interval: String?

    private var prompt: String {
        switch study.direction {
        case .termToDef: return study.card.term
        case .defToTerm: return study.card.definition ?? study.card.term
        }
    }

    private var answer: String? {
        switch study.direction {
        case .termToDef: return study.card.definition
        case .defToTerm: return study.card.term
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(prompt)
                .font(.system(size: size(for: prompt), weight: .medium, design: .serif))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)

            // The rule and the answer share one block whose height never
            // changes, so revealing costs no layout — only opacity.
            VStack(spacing: 7) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 44, height: 1)
                Group {
                    if let answer, !answer.isEmpty {
                        Text(answer)
                            .font(.system(size: size(for: answer, ceiling: 22), weight: .regular))
                            .foregroundStyle(Theme.ink.opacity(0.92))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.6)
                    } else {
                        // A card added on the run, with the meaning still to
                        // come. Saying so is kinder than an empty half that
                        // reads as a failed load.
                        Text("no definition yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .padding(.top, 12)
            .opacity(revealed ? 1 : 0)

            if let notes = study.card.notes, !notes.isEmpty, revealed {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // What the previous answer bought. It belongs to the card that has
            // gone, so it sits away from this one's text, in the corner where a
            // footnote goes.
            if let interval, !revealed {
                Text("next in \(interval)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    /// Four rungs, far enough apart that a change reads as a deliberate drop
    /// rather than a wobble. A term is usually one word and gets the top rung;
    /// a definition is usually a phrase and starts one rung down.
    private func size(for text: String, ceiling: CGFloat = 30) -> CGFloat {
        let ladder: [(Int, CGFloat)] = [(22, 30), (60, 22), (140, 16), (.max, 12)]
        let base = ladder.first { text.count <= $0.0 }?.1 ?? 12
        return min(base, ceiling)
    }
}

private struct RatingLabel: View {
    let rating: Rating
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 1) {
            Text(rating.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.color(for: rating))
            KeyCap(label: "\(rating.digit)", tint: Theme.color(for: rating).opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.color(for: rating).opacity(hovering ? 0.22 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.color(for: rating).opacity(hovering ? 0.5 : 0.22), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Theme.contentAnimation, value: hovering)
    }
}

/// A small pill. Used for anything that names a state rather than doing
/// something: the mode, a tag, "new".
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.tertiary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(
            Capsule().fill(tint.opacity(0.12))
        )
    }
}

extension StudyMode {
    /// Cycled by the chip. See the comment at its call site.
    var next: StudyMode {
        let all = StudyMode.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

extension StudyDirection {
    /// Cycled by the chip rather than chosen from a menu: there are three, and
    /// the one you want is never more than two presses away.
    var next: StudyDirection {
        let all = StudyDirection.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}
