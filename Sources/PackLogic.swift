import Foundation

/// Pure logic for the per-day set history and the opt-in Pack feature
/// (message text, digest gating). No UserDefaults, no networking — everything
/// here is unit-tested headlessly by `./build.sh --test`.
enum PackLogic {
    /// The one definition of the day-key format (zero-padded yyyy-MM-dd, so
    /// lexical order == chronological order). Prefs.dayString delegates here.
    /// Built per call rather than cached: a cached DateFormatter pins the
    /// timezone it saw at first use, which goes stale on a long-running
    /// menu-bar app when the Mac changes timezones.
    static func dayString(_ date: Date) -> String {
        dayFormatter().string(from: date)
    }

    static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// Record today's set count into the per-day history and drop entries older
    /// than `keepDays`. The log exists so the morning digest (and later, the
    /// pack view) can answer "how did the last few days go" — Prefs.setsToday
    /// alone forgets everything at day rollover.
    static func updatedDayLog(_ log: [String: Int], today: String, setsToday: Int,
                              keepDays: Int = 30) -> [String: Int] {
        var out = log
        out[today] = setsToday
        let formatter = dayFormatter()
        guard let todayDate = formatter.date(from: today),
              let cutoff = Calendar.current.date(byAdding: .day, value: -(keepDays - 1), to: todayDate)
        else { return out }
        let cutoffKey = formatter.string(from: cutoff)
        return out.filter { $0.key >= cutoffKey }
    }

    /// One digest per calendar day, and never before 06:00 so a Mac that's awake
    /// past midnight doesn't post "yesterday" seconds after it ends.
    static func shouldPostDigest(enabled: Bool, lastDigestDay: String,
                                 today: String, hour: Int) -> Bool {
        enabled && hour >= 6 && lastDigestDay != today
    }

    static func setMessage(name: String, reps: Int, setsToday: Int, streak: Int) -> String {
        "🏋️ \(name) finished a set — \(reps) squats · \(plural(setsToday, "set")) today · 🔥 \(streak)-day streak"
    }

    static func digestMessage(name: String, yesterdaySets: Int) -> String {
        yesterdaySets > 0
            ? "🌅 Yesterday: \(name) — \(plural(yesterdaySets, "set"))"
            : "🌅 Yesterday: \(name) — 0 sets. Today's a new day 💪"
    }

    static func testMessage(name: String) -> String {
        "👋 \(name) joined the pack — this is a Squat Coach test post"
    }

    static func webhookPayload(text: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["text": text])
    }

    private static func plural(_ n: Int, _ unit: String) -> String {
        n == 1 ? "1 \(unit)" : "\(n) \(unit)s"
    }
}
