import SwiftUI

/// Where the collection stands.
///
/// Four numbers, a month of activity, and the words that keep beating you.
/// Everything here is read at a glance and none of it is actionable, which is
/// why it is the one tab with nothing to press.
struct StatsPane: View {
    @ObservedObject var stats: StatsStore

    var body: some View {
        Group {
            if let response = stats.stats {
                content(response)
            } else if stats.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 20, weight: .light))
                    Text(stats.notice ?? "Nothing to show yet.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(Theme.contentAnimation, value: stats.stats?.study.totalReviews)
    }

    private func content(_ response: StatsResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Tile(value: "\(response.schedule.dueNow)", label: "due now", tint: response.schedule.dueNow > 0 ? Theme.accent : Theme.secondary)
                Tile(value: "\(response.schedule.newCount)", label: "unseen")
                Tile(value: "\(response.collection.totalCards)", label: "cards")
                Tile(
                    value: response.study.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                    label: "correct"
                )
                // Reviews, not the streak: the streak is already in the header
                // strip, and five tiles saying five different things beats four
                // and an echo.
                Tile(value: "\(response.study.totalReviews)", label: "reviews")
            }

            Activity(days: Self.series(from: response.reviewsLast30Days))

            HStack(alignment: .top, spacing: 18) {
                Breakdown(schedule: response.schedule, collection: response.collection, study: response.study)
                    .frame(width: 250, alignment: .leading)
                Leeches(cards: response.leeches, longest: response.longestStreakDays)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
    }
}

extension StatsPane {
    /// Fills the gaps.
    ///
    /// `/stats` reports only the days that had reviews in them — two rows, if
    /// you studied twice this month. Drawn straight, that is two bars stretched
    /// across the width of the panel, which reads as "you studied constantly"
    /// and means the opposite. Thirty slots, most of them zero, is the honest
    /// picture and the one the web client's heatmap draws.
    ///
    /// Days are cut in UTC because that is how the server groups them; using
    /// the local calendar here would shift every bar by one for anybody far
    /// enough east or west.
    static func series(from days: [DailyActivity], length: Int = 30) -> [DailyActivity] {
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let today = Date()
        return (0..<length).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = formatter.string(from: date)
            return byDay[key] ?? DailyActivity(day: key, reviews: 0, correct: 0)
        }
    }
}

private struct Tile: View {
    let value: String
    let label: String
    var tint: Color = Theme.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
    }
}

/// Thirty days of reviews, one bar each.
///
/// Bars rather than the web client's year-long heatmap: a heatmap needs a
/// square per day and 53 columns of them, which is a shape that belongs in a
/// page. Thirty bars say the same thing about the last month, which is the part
/// anybody acts on.
private struct Activity: View {
    let days: [DailyActivity]

    private var peak: Int { max(days.map(\.reviews).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("LAST 30 DAYS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                Spacer()
                Text("\(days.reduce(0) { $0 + $1.reviews }) reviews")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(colour(for: day.reviews))
                        .frame(height: max(3, CGFloat(day.reviews) / CGFloat(peak) * 72))
                        .frame(maxWidth: .infinity)
                        .help("\(day.day): \(day.reviews)")
                }
            }
            .frame(height: 72, alignment: .bottom)
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

private struct Breakdown: View {
    let schedule: ScheduleStats
    let collection: CollectionStats
    let study: StudyStats

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SCHEDULE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
            row("learning", schedule.learning, Theme.hard)
            row("review", schedule.review, Theme.good)
            row("relearning", schedule.relearning, Theme.again)
            row("due today", schedule.dueToday, Theme.accent)
            row("never studied", study.neverStudied, Theme.tertiary)
            // The count this app exists to bring down: words captured on the
            // run, meaning still to come.
            row("without a meaning", collection.cardsWithoutDefinition, Theme.tertiary)
        }
    }

    private func row(_ label: String, _ value: Int, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 6)
            Text("\(value)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
    }
}

/// The words that keep coming back. Named the way the backend names them, and
/// listed because a leech is the one statistic that tells you to go and do
/// something — rewrite the card, or let it go.
private struct Leeches: View {
    let cards: [LeechCard]
    let longest: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("FORGOTTEN MOST")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
            if cards.isEmpty {
                Text("Nothing has beaten you four times yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(cards.prefix(5)) { card in
                HStack(spacing: 6) {
                    Text(card.term)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(card.lapses)×")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.hard)
                }
            }
            Spacer(minLength: 0)
            Text("Longest streak: \(longest) day\(longest == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
    }
}
