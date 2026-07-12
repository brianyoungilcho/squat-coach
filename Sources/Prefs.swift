import Foundation

/// Tiny UserDefaults-backed settings + streak store. No database — this is a
/// personal single-user app, so flat keys are the right amount of machinery.
@MainActor enum Prefs {
    private static let d = UserDefaults.standard

    /// Registered once at launch so first-run reads sensible values.
    static func registerDefaults() {
        d.register(defaults: [
            "intervalMinutes": 60,
            "targetReps": 30,
            "soundEnabled": true,
            "sensitivity": 1,   // 0 = Easy (shallow), 1 = Normal, 2 = Strict (deep)
            "remindersEnabled": true,
            "packNotificationShowsNames": false,
        ])
    }

    /// 0 = Easy, 1 = Normal, 2 = Strict. Higher index = must squat deeper to count.
    static var sensitivity: Int {
        get { min(2, max(0, d.integer(forKey: "sensitivity"))) }
        set { d.set(min(2, max(0, newValue)), forKey: "sensitivity") }
    }
    /// How deep a squat must go to count, as a fraction of the user's own standing
    /// height (the prominence gate in SquatCounter). Easy counts a shallow-but-real
    /// dip; Strict requires a deep squat. Higher = must go deeper.
    static var sensitivityMinPromFrac: Double { [0.16, 0.24, 0.32][sensitivity] }
    /// HUD visual guide only: a rough depth mark to aim the on-screen bar below.
    /// (Counting itself is relative to standing, not this absolute value.)
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
    static var remindersEnabled: Bool {
        get { d.bool(forKey: "remindersEnabled") }
        set { d.set(newValue, forKey: "remindersEnabled") }
    }
    static var onboardingCompleted: Bool {
        get { d.bool(forKey: "onboardingCompleted") }
        set { d.set(newValue, forKey: "onboardingCompleted") }
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

    /// Per-day completed-set counts for the last ~30 days (yyyy-MM-dd → sets),
    /// kept for the pack digest and future history views — setsToday alone
    /// forgets the count at day rollover.
    static var dayLog: [String: Int] {
        get { (d.dictionary(forKey: "dayLog") ?? [:]).compactMapValues { $0 as? Int } }
        set { d.set(newValue, forKey: "dayLog") }
    }

    static func dayString(_ date: Date) -> String { HistoryLogic.dayString(date) }

    /// Record a completed set: bump today's count and advance the daily streak.
    static func recordCompletedSet() {
        setsToday += 1
        lastSetAt = Date()
        let today = dayString(Date())
        dayLog = HistoryLogic.updatedDayLog(dayLog, today: today, setsToday: setsToday)
        guard lastCompletedDay != today else { return }   // streak already counted today
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date()).map(dayString) ?? ""
        currentStreak = (lastCompletedDay == yesterday) ? currentStreak + 1 : 1
        lastCompletedDay = today
    }

    static var partialRepsToday: Int {
        get {
            guard d.string(forKey: "partialRepsDay") == dayString(Date()) else { return 0 }
            return d.integer(forKey: "partialRepsCount")
        }
        set {
            d.set(dayString(Date()), forKey: "partialRepsDay")
            d.set(max(0, newValue), forKey: "partialRepsCount")
        }
    }

    static func recordPartialEffort(reps: Int) {
        guard reps > 0 else { return }
        partialRepsToday += reps
        lastSetAt = Date()
    }

    // MARK: - Social Packs v2

    /// The active Pack is not a credential; authorization remains bound to the
    /// Keychain-backed Supabase session and server-side membership.
    static var activeSocialPackId: UUID? {
        get {
            guard let raw = d.string(forKey: "activeSocialPackId") else { return nil }
            return UUID(uuidString: raw)
        }
        set { d.set(newValue?.uuidString.lowercased(), forKey: "activeSocialPackId") }
    }

    static var socialDisplayName: String {
        get { d.string(forKey: "socialDisplayName") ?? "" }
        set {
            d.set(
                String(newValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)),
                forKey: "socialDisplayName"
            )
        }
    }

    static var packNotificationShowsNames: Bool {
        get { d.bool(forKey: "packNotificationShowsNames") }
        set { d.set(newValue, forKey: "packNotificationShowsNames") }
    }

    static var acknowledgedSocialPackReset: Bool {
        get { d.bool(forKey: "acknowledgedSocialPackReset") }
        set { d.set(newValue, forKey: "acknowledgedSocialPackReset") }
    }

    static var hasLegacyPackConfiguration: Bool {
        d.bool(forKey: "packShareEnabled") ||
            !(d.string(forKey: "packCode") ?? "").isEmpty ||
            !(d.string(forKey: "packWebhookURL") ?? "").isEmpty
    }

    static func clearLegacyPackConfiguration() {
        for key in [
            "packShareEnabled",
            "packCode",
            "packWebhookURL",
            "packDisplayName",
            "packSnapshot",
            "packSnapshotDay",
            "packMemberId",
            "lastDigestDay",
        ] {
            d.removeObject(forKey: key)
        }
    }
}
