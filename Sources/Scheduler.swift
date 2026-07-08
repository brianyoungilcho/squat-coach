import Foundation
import AppKit

/// Fires `onFire` every `intervalMinutes`, aligned to the wall clock, and holds
/// an activity token so App Nap doesn't suspend the timer while we're idle in
/// the menu bar. A single-shot timer that reschedules itself is more robust than
/// a repeating one — it re-reads the interval each cycle, so a settings change
/// takes effect on the next fire without teardown.
@MainActor
final class Scheduler {
    var onFire: (() -> Void)?

    /// When the next reminder will fire (for the menu's "next set in …" line).
    private(set) var nextFire: Date?

    private var timer: Timer?
    private var activity: NSObjectProtocol?

    func start() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated], reason: "Hourly squat reminder")
        }
        scheduleNext()
    }

    /// Re-arm after the interval changes in settings.
    func reschedule() { scheduleNext() }

    /// Manual "Squats now" from the menu.
    func triggerNow() { onFire?() }

    private func scheduleNext() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, Prefs.intervalMinutes) * 60)
        // Next boundary measured from the top of the current hour, so a 60-min
        // interval lands on :00 and shorter intervals stay phase-locked to it.
        let now = Date()
        let startOfHour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        var fire = startOfHour
        while fire <= now { fire = fire.addingTimeInterval(interval) }
        nextFire = fire
        let t = Timer(timeInterval: fire.timeIntervalSince(now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onFire?()
                self.scheduleNext()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
