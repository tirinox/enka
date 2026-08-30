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

    /// Five minutes. The scheduler's shortest interval is about a minute, so a
    /// faster poll would mostly re-learn the same number; slower, and a card
    /// that came due while you were reading would not show up until you had
    /// stopped caring.
    private let pollInterval: TimeInterval = 300

    init(session: Session) {
        self.session = session
    }

    func startPolling() {
        stopPolling()
        Task { await refreshDue() }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshDue() }
        }
        // A minute of slack on a five-minute beat: the system can fold this
        // wake-up into one it was making anyway, and nothing here is worse for
        // arriving late.
        timer.tolerance = 60
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
        isLoading = stats == nil
        work = Task {
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
    }
}
