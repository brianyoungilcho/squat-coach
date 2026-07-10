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
            "packShareEnabled": false,
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

    static func dayString(_ date: Date) -> String { PackLogic.dayString(date) }

    /// Record a completed set: bump today's count and advance the daily streak.
    static func recordCompletedSet() {
        setsToday += 1
        lastSetAt = Date()
        let today = dayString(Date())
        dayLog = PackLogic.updatedDayLog(dayLog, today: today, setsToday: setsToday)
        guard lastCompletedDay != today else { return }   // streak already counted today
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date()).map(dayString) ?? ""
        currentStreak = (lastCompletedDay == yesterday) ? currentStreak + 1 : 1
        lastCompletedDay = today
    }

    // MARK: - Pack sharing (opt-in, off by default)

    static var packShareEnabled: Bool {
        get { d.bool(forKey: "packShareEnabled") }
        set { d.set(newValue, forKey: "packShareEnabled") }
    }
    /// The pack's shared Slack incoming-webhook URL (https://hooks.slack.com/…).
    static var packWebhookURL: String {
        get { d.string(forKey: "packWebhookURL") ?? "" }
        set { d.set(newValue, forKey: "packWebhookURL") }
    }
    /// Name shown to the pack; empty means "use the macOS account's full name".
    static var packDisplayName: String {
        get { d.string(forKey: "packDisplayName") ?? "" }
        set { d.set(newValue, forKey: "packDisplayName") }
    }
    static var packResolvedName: String {
        let n = packDisplayName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? NSFullUserName() : n
    }
    /// yyyy-MM-dd of the last day a morning digest was posted (or consumed).
    static var lastDigestDay: String {
        get { d.string(forKey: "lastDigestDay") ?? "" }
        set { d.set(newValue, forKey: "lastDigestDay") }
    }

    // MARK: - Pack sync (shared backend; see supabase/schema.sql)

    /// The pack's bearer code in canonical form (generated, hyphen-free, e.g.
    /// "SQTK7MP29WXTV3RHBD" — see PackSyncLogic). Normalized on BOTH read and
    /// write so every path, including values restored from a prefs backup or
    /// written via `defaults`, stays canonical. Empty = no sync.
    static var packCode: String {
        get { PackSyncLogic.normalizedPackCode(d.string(forKey: "packCode") ?? "") }
        set { d.set(PackSyncLogic.normalizedPackCode(newValue), forKey: "packCode") }
    }
    /// Stable per-install identity, minted on first use — display names can
    /// change or collide; this can't.
    static var packMemberId: String {
        if let existing = d.string(forKey: "packMemberId") { return existing }
        let fresh = UUID().uuidString.lowercased()
        d.set(fresh, forKey: "packMemberId")
        return fresh
    }
    /// Backend overrides for self-hosters (README); empty = the shipped project.
    static var packBackendURL: String {
        let s = d.string(forKey: "packBackendURL") ?? ""
        return s.isEmpty ? PackSyncLogic.defaultBaseURL : s
    }
    static var packBackendKey: String {
        let s = d.string(forKey: "packBackendKey") ?? ""
        return s.isEmpty ? PackSyncLogic.defaultKey : s
    }
    /// Last-seen today-counts per member (for friend-finished notifications).
    static var packSnapshotDay: String {
        get { d.string(forKey: "packSnapshotDay") ?? "" }
        set { d.set(newValue, forKey: "packSnapshotDay") }
    }
    static var packSnapshot: [String: Int] {
        get { (d.dictionary(forKey: "packSnapshot") ?? [:]).compactMapValues { $0 as? Int } }
        set { d.set(newValue, forKey: "packSnapshot") }
    }
}
