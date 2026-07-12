import Foundation

enum ReminderSchedule {
    /// Returns the next cadence point after `now`. A delayed timer skips
    /// cadence points that have already passed instead of rapid catch-up.
    static func nextFireDate(
        now: Date,
        interval: TimeInterval,
        previousScheduledFire: Date?
    ) -> Date {
        let cadence = max(1, interval)
        guard let previousScheduledFire else {
            return now.addingTimeInterval(cadence)
        }
        let next = previousScheduledFire.addingTimeInterval(cadence)
        guard next <= now else { return next }
        let missedIntervals = floor(now.timeIntervalSince(next) / cadence) + 1
        return next.addingTimeInterval(missedIntervals * cadence)
    }
}
