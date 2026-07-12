import Foundation

/// Fires `onFire` every `intervalMinutes`. A single-shot timer that reschedules
/// itself preserves 45/90-minute cadence, skips delayed catch-up bursts, and
/// re-reads preferences after every fire.
@MainActor
final class Scheduler {
    var onFire: (() -> Void)?

    /// When the next reminder will fire (for the menu's "next set in …" line).
    private(set) var nextFire: Date?

    private var timer: Timer?

    func start() {
        guard Prefs.remindersEnabled else {
            stop()
            return
        }
        scheduleNext(previousScheduledFire: nil)
    }

    /// Re-arm after the interval changes in settings.
    func reschedule() { start() }

    func stop() {
        timer?.invalidate()
        timer = nil
        nextFire = nil
    }

    /// Manual "Squats now" from the menu.
    func triggerNow() { onFire?() }

    private func scheduleNext(previousScheduledFire: Date?) {
        timer?.invalidate()
        let interval = TimeInterval(max(1, Prefs.intervalMinutes) * 60)
        let now = Date()
        let fire = ReminderSchedule.nextFireDate(
            now: now, interval: interval, previousScheduledFire: previousScheduledFire)
        nextFire = fire
        let t = Timer(timeInterval: fire.timeIntervalSince(now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onFire?()
                self.scheduleNext(previousScheduledFire: fire)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
