import SwiftUI

/// Where the collection stands.
///
/// Five numbers, a month of activity, what the scheduler is holding, and the
/// words that keep beating you. Nothing here is actionable except the last
/// list, which is the point of it: a leech is the one statistic that tells you
/// to go and do something — rewrite the card, or let it go — so those rows open
/// the editor and the rest of the screen is read.
struct StatsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var tagStore: TagStore
    @EnvironmentObject private var audio: AudioPlayback

    @State private var editing: Card?
    @State private var opening: String?

    var body: some View {
        NavigationStack {
            Group {
                if let response = stats.stats {
                    content(response)
                } else if stats.isLoading {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyNotice(
                        symbol: "chart.bar",
                        message: stats.notice ?? "Nothing to show yet.",
                        tint: stats.notice == nil ? Theme.textFaint : Theme.danger,
                        action: ("Try again", { stats.refresh() })
                    )
                }
            }
            .background(Theme.bg)
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.accent)
        .task { stats.refresh() }
        .sheet(item: $editing) { card in
            CardEditorView(session: session, card: card, tags: tagStore, audio: audio) { outcome in
                switch outcome {
                case let .saved(card): library.apply(card)
                case let .deleted(id): library.remove(id: id)
                }
                // The leech list is a query, not a cache: a card rewritten or
                // deleted is a different answer to it.
                stats.refresh()
            }
        }
        .animation(Theme.normal, value: stats.stats?.study.totalReviews)
    }

    private func content(_ response: StatsResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                tiles(response)
                Activity(days: StatsStore.series(from: response.reviewsLast30Days))
                schedule(response)
                leeches(response)
                streaks(response)
            }
            .padding(20)
        }
        .refreshable { await stats.reload() }
    }

    // MARK: - The numbers

    private func tiles(_ response: StatsResponse) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(
                value: "\(response.schedule.dueNow)",
                label: "due now",
                tint: response.schedule.dueNow > 0 ? Theme.accent : Theme.text
            )
            StatTile(value: "\(response.reviewsToday)", label: "answered today")
            StatTile(value: "\(response.collection.totalCards)", label: "cards")
            StatTile(value: "\(response.schedule.newCount)", label: "unseen")
            StatTile(
                value: response.study.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                label: "correct"
            )
            StatTile(value: "\(response.study.totalReviews)", label: "reviews")
        }
    }

    // MARK: - Schedule

    private func schedule(_ response: StatsResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Schedule")
            breakdown("learning", response.schedule.learning, Theme.hard)
            breakdown("review", response.schedule.review, Theme.good)
            breakdown("relearning", response.schedule.relearning, Theme.again)
            breakdown("due today", response.schedule.dueToday, Theme.accent)
            breakdown("never studied", response.study.neverStudied, Theme.textFaint)
            // The count this app exists to bring down: words captured on the
            // run, meaning still to come.
            breakdown("without a meaning", response.collection.cardsWithoutDefinition, Theme.textFaint)
        }
    }

    private func breakdown(_ label: String, _ value: Int, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 8)
            Text("\(value)")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(Theme.text)
        }
    }

    // MARK: - Leeches

    private func leeches(_ response: StatsResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Forgotten most")
            if response.leeches.isEmpty {
                Text("Nothing has beaten you four times yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textFaint)
            }
            ForEach(response.leeches) { leech in
                Button {
                    open(leech)
                } label: {
                    HStack(spacing: 8) {
                        Text(leech.term)
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if opening == leech.id {
                            ProgressView()
                        } else {
                            Text("\(leech.lapses)×")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.hard)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// `/stats` names a leech but does not carry the card, so the row fetches
    /// the one it names before opening the editor on it. A leech is worth a
    /// round trip: it is the row somebody taps having decided to fix something.
    private func open(_ leech: LeechCard) {
        guard opening == nil else { return }
        opening = leech.id
        Task {
            defer { opening = nil }
            // The list has it whenever the collection is small enough to have
            // been paged in, which saves the request in the common case.
            if let known = library.cards.first(where: { $0.id == leech.id }) {
                editing = known
                return
            }
            guard let found = try? await session.run({ try await $0.search(leech.term, limit: 5) }),
                  let hit = found.hits.first(where: { $0.card.id == leech.id }) else { return }
            editing = hit.card
        }
    }

    // MARK: - Streaks

    private func streaks(_ response: StatsResponse) -> some View {
        HStack(spacing: 10) {
            Label(
                "\(response.currentStreakDays) day\(response.currentStreakDays == 1 ? "" : "s") running",
                systemImage: "flame.fill"
            )
            .foregroundStyle(response.currentStreakDays > 0 ? Theme.accent : Theme.textFaint)
            Spacer(minLength: 8)
            Text("best \(response.longestStreakDays)")
                .foregroundStyle(Theme.textFaint)
        }
        .font(.footnote.weight(.medium))
        .padding(.bottom, 8)
    }
}

/// Thirty days of reviews, one bar each.
///
/// Bars rather than the web client's year-long heatmap: a heatmap needs a
/// square per day and 53 columns of them, which is a shape that belongs on a
/// page and not on a phone held upright. Thirty bars say the same thing about
/// the last month, which is the part anybody acts on.
private struct Activity: View {
    let days: [DailyActivity]

    private var peak: Int { max(days.map(\.reviews).max() ?? 0, 1) }
    private var total: Int { days.reduce(0) { $0 + $1.reviews } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Last 30 days")
                Spacer()
                Text("\(total) reviews")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(colour(for: day.reviews))
                        .frame(height: max(3, CGFloat(day.reviews) / CGFloat(peak) * 84))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("\(day.day): \(day.reviews) reviews")
                }
            }
            .frame(height: 84, alignment: .bottom)
        }
    }

    /// The web client's ramp, so a good week looks the same in both places.
    private func colour(for reviews: Int) -> Color {
        guard reviews > 0 else { return Theme.heat[0] }
        let share = Double(reviews) / Double(peak)
        let index = min(Theme.heat.count - 1, 1 + Int(share * 3.99))
        return Theme.heat[index]
    }
}
