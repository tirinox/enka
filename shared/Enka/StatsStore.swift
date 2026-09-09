import Combine
import Foundation

/// The stats tab, and the number in the menu bar.
///
/// Two jobs with two schedules. The full picture is fetched when the tab is
/// looked at, because nothing on it changes between one hover and the next. The
/// due count is fetched on a slow timer whether or not anybody is looking,
/// because it is the thing that gets somebody to look.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var stats: StatsResponse?
    @Published private(set) var isLoading = false
    @Published private(set) var notice: String?
    /// What the menu bar shows. Kept apart from `stats` so the badge survives
    /// the tab being closed and the full response being let go of.
    @Published private(set) var dueNow: Int?

    private let session: Session
    private var timer: Timer?
    private var work: Task<Void, Never>?

    /// A minute.
    ///
    /// It was five, on the reasoning that the scheduler's shortest interval is
    /// about a minute so a faster poll would mostly re-learn the same number.
    /// That was right about cards coming due and wrong about everything else:
    /// what actually moves this number is the collection being answered from
    /// another client, and at five minutes the badge and the phone could
    /// disagree by a whole study session.
    private let pollInterval: TimeInterval = 60

    init(session: Session) {
        self.session = session
    }

    func startPolling() {
        stopPolling()
        Task { await refreshDue() }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshDue() }
        }
        // A quarter of the beat as slack: the system can fold this wake-up
        // into one it was making anyway, and nothing here is worse for arriving
        // a little late.
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// The cheap call — `/study/queue?limit=1`, which reports what is due
    /// without marking anything as shown.
    func refreshDue() async {
        guard let count = try? await session.run({ try await $0.remainingDue() }) else { return }
        dueNow = count
    }

    func refresh() {
        work?.cancel()
        work = Task { await load() }
    }

    /// The same fetch, awaited — what a pull-to-refresh gesture holds its
    /// spinner open for. `refresh` cannot be it: a gesture that returns the
    /// moment a task is spawned snaps shut before the numbers under it move.
    func reload() async {
        work?.cancel()
        await load()
    }

    private func load() async {
        isLoading = stats == nil
        do {
            let response = try await session.run { try await $0.stats() }
            guard !Task.isCancelled else { return }
            stats = response
            dueNow = response.schedule.dueNow
            notice = nil
        } catch is CancellationError {
            return
        } catch let error as APIError {
            notice = error.message
        } catch {
            notice = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Shaping

    /// Fills the gaps in `reviews_last_30_days`.
    ///
    /// `/stats` reports only the days that had reviews in them — two rows, if
    /// you studied twice this month. Drawn straight, that is two bars stretched
    /// across the width of a chart, which reads as "you studied constantly" and
    /// means the opposite. Thirty slots, most of them zero, is the honest
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
