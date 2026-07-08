import Foundation

/// Tiny UserDefaults-backed settings + streak store. No database — this is a
/// personal single-user app, so flat keys are the right amount of machinery.
enum Prefs {
    private static let d = UserDefaults.standard

    /// Registered once at launch so first-run reads sensible values.
    static func registerDefaults() {
        d.register(defaults: [
            "intervalMinutes": 60,
            "targetReps": 30,
            "soundEnabled": true,
            "sensitivity": 1,   // 0 = Easy (shallow), 1 = Normal, 2 = Strict (deep)
        ])
    }

    /// 0 = Easy, 1 = Normal, 2 = Strict. Higher index = must squat deeper to count.
    static var sensitivity: Int {
        get { min(2, max(0, d.integer(forKey: "sensitivity"))) }
        set { d.set(min(2, max(0, newValue)), forKey: "sensitivity") }
    }
    /// Depth (fraction of standing hip-height) below which a rep's "down" begins.
    /// Easy counts shallow dips; Strict requires a deep squat.
    static var sensitivityDownEnter: Double { [0.70, 0.62, 0.54][sensitivity] }
    static var sensitivityLabel: String { ["Easy", "Normal", "Strict"][sensitivity] }

    static var intervalMinutes: Int {
        get { max(1, d.integer(forKey: "intervalMinutes")) }
        set { d.set(newValue, forKey: "intervalMinutes") }
    }
    static var targetReps: Int {
        get { max(1, d.integer(forKey: "targetReps")) }
        set { d.set(newValue, forKey: "targetReps") }
    }
    static var soundEnabled: Bool {
        get { d.bool(forKey: "soundEnabled") }
        set { d.set(newValue, forKey: "soundEnabled") }
    }

    // MARK: - Streak / history

    /// yyyy-MM-dd of the last day a set was completed.
    static var lastCompletedDay: String {
        get { d.string(forKey: "lastCompletedDay") ?? "" }
        set { d.set(newValue, forKey: "lastCompletedDay") }
    }
    static var currentStreak: Int {
        get { d.integer(forKey: "currentStreak") }
        set { d.set(newValue, forKey: "currentStreak") }
    }
    /// When the last set was completed (nil if never).
    static var lastSetAt: Date? {
        get { let t = d.double(forKey: "lastSetAt"); return t > 0 ? Date(timeIntervalSince1970: t) : nil }
        set { d.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "lastSetAt") }
    }
    /// Completed sets today (auto-resets when the day rolls over).
    static var setsToday: Int {
        get {
            guard d.string(forKey: "setsTodayDay") == dayString(Date()) else { return 0 }
            return d.integer(forKey: "setsTodayCount")
        }
        set {
            d.set(dayString(Date()), forKey: "setsTodayDay")
            d.set(newValue, forKey: "setsTodayCount")
        }
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// Record a completed set: bump today's count and advance the daily streak.
    static func recordCompletedSet() {
        setsToday += 1
        lastSetAt = Date()
        let today = dayString(Date())
        guard lastCompletedDay != today else { return }   // streak already counted today
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date()).map(dayString) ?? ""
        currentStreak = (lastCompletedDay == yesterday) ? currentStreak + 1 : 1
        lastCompletedDay = today
    }
}
