import Foundation

/// Posts pack updates to a user-supplied Slack incoming webhook. Strictly
/// opt-in (Prefs.packShareEnabled, off by default) and fire-and-forget:
/// sharing must never block, delay, or break a workout, so failures are
/// logged and dropped — at one message per finished set, Slack's ~1 msg/sec
/// webhook limit is unreachable and retries would only double-post.
/// Only the display name, set counts, and streak are ever sent; camera frames
/// and pose data never leave the Mac (see AGENTS.md).
enum PackShare {
    static func postSetCompleted(reps: Int) {
        guard Prefs.packShareEnabled else { return }
        post(PackLogic.setMessage(name: Prefs.packResolvedName, reps: reps,
                                  setsToday: Prefs.setsToday, streak: Prefs.currentStreak))
    }

    /// Called at launch and on every scheduler fire; posts yesterday's summary
    /// once per day after 06:00. The day is marked consumed before posting so a
    /// failed send skips quietly instead of retrying on every subsequent fire.
    static func postDigestIfNeeded(now: Date = Date()) {
        let today = Prefs.dayString(now)
        let hour = Calendar.current.component(.hour, from: now)
        guard PackLogic.shouldPostDigest(enabled: Prefs.packShareEnabled,
                                         lastDigestDay: Prefs.lastDigestDay,
                                         today: today, hour: hour) else { return }
        Prefs.lastDigestDay = today
        // No digest until there is at least one *prior* day of history — a
        // first-day user shouldn't be greeted with "Yesterday: 0 sets".
        guard Prefs.dayLog.keys.contains(where: { $0 != today }) else { return }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)
            .map(Prefs.dayString) ?? ""
        post(PackLogic.digestMessage(name: Prefs.packResolvedName,
                                     yesterdaySets: Prefs.dayLog[yesterday] ?? 0))
    }

    static func postTest() {
        guard Prefs.packShareEnabled else { return }
        post(PackLogic.testMessage(name: Prefs.packResolvedName))
    }

    private static func post(_ text: String) {
        guard let url = URL(string: Prefs.packWebhookURL), url.scheme == "https" else {
            NSLog("PackShare: webhook URL is missing or not https — post skipped")
            return
        }
        post(text, to: url)
    }

    /// Internal (not private) so a headless harness can drive the real request
    /// path against a local listener. The opt-in and https gates live in the
    /// wrapper above — production posts must route through it.
    static func post(_ text: String, to url: URL) {
        guard let body = PackLogic.webhookPayload(text: text) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err {
                NSLog("PackShare: post failed — %@", err.localizedDescription)
            } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                NSLog("PackShare: webhook returned HTTP %d", http.statusCode)
            }
        }.resume()
    }
}
