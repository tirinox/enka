import SwiftUI
import UIKit

/// One card, filling the screen, answered with a thumb.
///
/// The whole store behind this — fetching, revealing, rating, undo, the
/// `elapsed_ms` the scheduler wants — is `StudySession`, unchanged from the
/// Mac. What is different is the shape: the Mac reads a card out of the corner
/// of an eye and answers it with the number keys, and a phone has no keys and
/// the whole screen. So the word goes in the middle at a size readable at
/// arm's length, and everything that answers it goes in the bottom third,
/// where a thumb already is.
struct StudyView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var study: StudySession
    @Environment(\.scenePhase) private var scenePhase

    /// How far the card has been dragged, and which rating a release would
    /// therefore record. `pending` is derived from `drag`, but kept separately
    /// so that crossing the threshold can be felt exactly once.
    @State private var drag: CGSize = .zero
    @State private var pending: Rating?

    /// The streak and today's count as the server last reported them, plus the
    /// answer tally at that moment. Everything answered since is added on top,
    /// rather than asked for again.
    @State private var day: DaySeed?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            face
            bottom
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .tint(Theme.accent)
        .onAppear { study.setActive(true) }
        .task { await loadDay() }
        // Backgrounding the app is the phone's version of folding the panel:
        // audio stops and nothing is left in flight. The card survives it —
        // `setActive(true)` only fetches when there is nothing up — so
        // glancing at a notification does not cost the card being answered.
        .onChange(of: scenePhase) { _, phase in
            study.setActive(phase == .active)
            // A phone put down overnight comes back on a different day.
            if phase == .active { Task { await loadDay() } }
        }
        .animation(Theme.fast, value: pending)
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("\(study.remainingDue) due")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textMuted)
                .contentTransition(.numericText())
                .animation(Theme.normal, value: study.remainingDue)

            tallies

            Spacer()

            if study.undoableCard != nil {
                Button {
                    study.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 40, height: 40)
                }
                .transition(.opacity)
            }

            menu
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .animation(Theme.fast, value: study.undoableCard)
    }

    /// The streak and the day's tally, quiet next to the due count.
    ///
    /// The flame is grey until the day's first answer lands and then turns
    /// clay. That is the whole feedback loop of a streak — the moment it is
    /// safe for another day — and it costs one colour.
    @ViewBuilder private var tallies: some View {
        if let day {
            let today = max(0, day.reviews + study.recordedAnswers - day.baseline)
            // The server's streak already counts today if it had seen an
            // answer; the first one of the day is what extends the run.
            let streak = day.streak + (day.reviews == 0 && today > 0 ? 1 : 0)

            HStack(spacing: 12) {
                if streak > 0 {
                    Label("\(streak)", systemImage: "flame.fill")
                        .foregroundStyle(today > 0 ? Theme.accent : Theme.textFaint)
                        .accessibilityLabel("\(streak) day streak")
                }
                Label("\(today)", systemImage: "checkmark")
                    .foregroundStyle(Theme.textFaint)
                    .accessibilityLabel("\(today) answered today")
            }
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(Theme.normal, value: today)
        }
    }

    /// Seeded once per appearance rather than refetched per card: `/stats` is a
    /// dozen queries and a leech list, and the only part of it that moves while
    /// somebody studies moves by exactly one each time.
    private func loadDay() async {
        // Taken before the request, so an answer that lands mid-flight is
        // counted once — by the delta if the server missed it, and the seed is
        // replaced wholesale if it did not.
        let baseline = study.recordedAnswers
        guard let stats = try? await session.run({ try await $0.stats() }) else { return }
        day = DaySeed(reviews: stats.reviewsToday, streak: stats.currentStreakDays, baseline: baseline)
    }

    private var menu: some View {
        Menu {
            Picker("Mode", selection: $study.mode) {
                ForEach(StudyMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Asked", selection: $study.direction) {
                ForEach(StudyDirection.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Sign out", role: .destructive) { session.signOut() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 40, height: 40)
        }
    }

    // MARK: - The card

    @ViewBuilder private var face: some View {
        switch study.phase {
        case .idle, .loading:
            centred { ProgressView().tint(Theme.accent) }

        case let .card(card, revealed):
            CardFace(study: card, revealed: revealed, interval: study.lastInterval)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(drag)
                // A card being flicked away tilts. Horizontal only, and
                // capped: past about nine degrees it stops reading as physics
                // and starts reading as a bug.
                .rotationEffect(.degrees(min(max(drag.width / 26, -9), 9)), anchor: .bottom)
                // The whole area, not the words: the target for "I remember
                // it, show me" should be everything the thumb cannot miss.
                .contentShape(Rectangle())
                .onTapGesture { reveal() }
                .gesture(dragGesture)
                .overlay(alignment: .top) { verdict }

        case .empty:
            centred {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.good)
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
            }

        case let .failed(message):
            centred {
                VStack(spacing: 16) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                    Button("Try again") { study.reload() }
                        .buttonStyle(SoftButtonStyle())
                        .fixedSize()
                }
                .padding(.horizontal, 28)
            }
        }
    }

    /// "Nothing due" is good news in `due` mode and a filter problem in `new`.
    /// Saying which costs a line and saves a puzzled minute.
    private var emptyMessage: String {
        switch study.mode {
        case .due, .smart: return "Nothing due.\nCome back later."
        case .new: return "No unseen cards left — add some."
        case .reinforce: return "Nothing to reinforce yet."
        case .random: return "The collection is empty."
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom

    /// Fixed height whatever is in it, so revealing an answer never moves the
    /// card above it.
    @ViewBuilder private var bottom: some View {
        Group {
            if let notice = study.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if case let .card(_, revealed) = study.phase {
                if revealed {
                    ratings
                } else {
                    Button("Show answer") { study.reveal() }
                        .buttonStyle(AccentButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 92)
        .animation(Theme.normal, value: study.isRevealed)
    }

    private var ratings: some View {
        HStack(spacing: 8) {
            ForEach(Rating.allCases) { rating in
                Button {
                    answer(rating)
                } label: {
                    VStack(spacing: 2) {
                        Text(rating.title)
                            .font(.subheadline.weight(.semibold))
                        // What the press buys, before it is pressed. Until the
                        // server started sending this with the card, the only
                        // way to learn it was to have already chosen.
                        if let interval = study.currentCard?.intervals?[rating] {
                            Text(compact(interval))
                                .font(.caption2)
                                .opacity(0.8)
                        }
                    }
                }
                .buttonStyle(RatingButtonStyle(rating: rating))
            }
        }
    }

    // MARK: - Answering with the thumb

    /// Left is `again`, right is `good`, down is `hard`, up is `easy` — the
    /// four laid out the way the buttons are, so the drag is the buttons
    /// without having to look at them.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard study.isRevealed else { return }
                drag = value.translation
                let next = rating(for: value.translation)
                guard next != pending else { return }
                pending = next
                // The haptic that makes this work without looking: it fires
                // the moment a release would start counting, and again if the
                // thumb wanders back below the threshold.
                UISelectionFeedbackGenerator().selectionChanged()
            }
            .onEnded { _ in
                guard study.isRevealed else { return }
                if let pending {
                    commit(pending)
                } else {
                    withAnimation(Theme.normal) { drag = .zero }
                }
            }
    }

    /// Which rating a release would record, or nil while the drag is still
    /// short enough to be a change of mind. The larger component wins, so a
    /// sloppy diagonal still means something.
    private func rating(for translation: CGSize) -> Rating? {
        let threshold: CGFloat = 84
        if abs(translation.width) >= abs(translation.height) {
            guard abs(translation.width) > threshold else { return nil }
            return translation.width < 0 ? .again : .good
        }
        guard abs(translation.height) > threshold else { return nil }
        return translation.height < 0 ? .easy : .hard
    }

    /// Throws the card off the screen in the direction it was going, then
    /// answers. The wait is the length of the animation: answering first would
    /// swap the card underneath its own exit.
    private func commit(_ rating: Rating) {
        feedback(for: rating)
        pending = nil
        withAnimation(.easeIn(duration: 0.18)) { drag = exit(for: rating) }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            study.answer(rating)
            drag = .zero
        }
    }

    private func exit(for rating: Rating) -> CGSize {
        switch rating {
        case .again: return CGSize(width: -700, height: drag.height)
        case .good: return CGSize(width: 700, height: drag.height)
        case .easy: return CGSize(width: drag.width, height: -900)
        case .hard: return CGSize(width: drag.width, height: 900)
        }
    }

    private func answer(_ rating: Rating) {
        feedback(for: rating)
        study.answer(rating)
    }

    private func reveal() {
        guard !study.isRevealed else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        study.reveal()
    }

    /// The two that carry a verdict get the system's verdict haptics; the two
    /// in the middle get a plain knock, hard heavier than good. Pressed or
    /// dragged, the same rating feels the same.
    private func feedback(for rating: Rating) {
        switch rating {
        case .again: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .easy: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .hard: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .good: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }

    /// What a release would record, named and priced, in the rating's colour.
    /// It fades in with the drag so the answer is legible before the thumb
    /// commits to it.
    @ViewBuilder private var verdict: some View {
        if let pending {
            VStack(spacing: 2) {
                Text(pending.title)
                    .font(.title3.weight(.bold))
                if let interval = study.currentCard?.intervals?[pending] {
                    Text("next in \(interval)")
                        .font(.footnote)
                }
            }
            .foregroundStyle(Theme.color(for: pending))
            .padding(.top, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    /// "8 days" → "8d". The server's phrasing is right for a sentence and too
    /// long for a quarter of a phone's width.
    private func compact(_ interval: String) -> String {
        let parts = interval.split(separator: " ")
        guard parts.count == 2 else { return interval }
        let units = [
            "second": "s", "seconds": "s", "minute": "m", "minutes": "m",
            "hour": "h", "hours": "h", "day": "d", "days": "d",
            "month": "mo", "months": "mo", "year": "y", "years": "y",
        ]
        guard let unit = units[String(parts[1])] else { return interval }
        return parts[0] + unit
    }
}

// MARK: - Pieces

/// What `/stats` said, and when — "when" being the answer tally at the moment
/// it was asked, which is what makes the delta since meaningful.
private struct DaySeed {
    let reviews: Int
    let streak: Int
    let baseline: Int
}


/// The card itself: prompt above, answer below once it has been earned.
///
/// Both halves are laid out whether or not the answer is showing, and the
/// answer is faded in rather than inserted. Inserting it moves the prompt, and
/// a prompt that jumps upward at the moment of recall pulls the eye away from
/// the exact place the answer is about to appear.
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
            Spacer(minLength: 0)

            Text(prompt)
                .font(.system(size: size(for: prompt), weight: .medium, design: .serif))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)

            VStack(spacing: 16) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 64, height: 1)

                if let answer, !answer.isEmpty {
                    Text(answer)
                        .font(.system(size: size(for: answer, ceiling: 30)))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                } else {
                    // A card added on the run, with the meaning still to come.
                    // Saying so is kinder than an empty half that reads as a
                    // failed load.
                    Text("no definition yet")
                        .font(.callout)
                        .foregroundStyle(Theme.textFaint)
                }

                if let notes = study.card.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(Theme.textFaint)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 28)
            .opacity(revealed ? 1 : 0)

            Spacer(minLength: 0)
        }
        .animation(Theme.normal, value: revealed)
        .overlay(alignment: .bottom) {
            // What the *previous* answer bought. It belongs to the card that
            // has gone, so it sits away from this one's words, where a
            // footnote goes.
            if let interval, !revealed {
                Text("next in \(interval)")
                    .font(.footnote)
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    /// Four rungs, far enough apart that a change reads as a deliberate drop
    /// rather than a wobble. A term is usually one word and gets the top rung;
    /// a phrase starts one rung down.
    private func size(for text: String, ceiling: CGFloat = 46) -> CGFloat {
        let ladder: [(Int, CGFloat)] = [(22, 46), (60, 34), (140, 25), (.max, 19)]
        let base = ladder.first { text.count <= $0.0 }?.1 ?? 19
        return min(base, ceiling)
    }
}

/// One of the four. Tall enough to hit without looking, and tinted with the
/// rating's own colour — the same four the web client and the Mac use, because
/// they are the only place in Enka where colour means something.
private struct RatingButtonStyle: ButtonStyle {
    let rating: Rating

    func makeBody(configuration: Configuration) -> some View {
        let tint = Theme.color(for: rating)
        return configuration.label
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.30 : 0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(tint.opacity(0.34), lineWidth: 1)
            )
            .animation(Theme.fast, value: configuration.isPressed)
    }
}
