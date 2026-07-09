import Foundation
import UserNotifications

/// Syncs pack state with the shared backend (Supabase PostgREST over plain
/// URLSession). Strictly opt-in: inert unless sharing is on AND a pack code is
/// set. Pushes only the display name, set counts, and streak; reads the whole
/// pack's recent days for the menu view and posts a local notification when a
/// packmate finishes a set. Fire-and-forget like PackShare — sync must never
/// block or break a workout, so failures are logged and dropped.
@MainActor
final class PackSync {
    static let shared = PackSync()

    /// Latest fetched pack state, oldest-refresh wins never — menu renders this.
    private(set) var summaries: [PackSyncLogic.MemberSummary] = []
    private(set) var lastRefresh: Date?
    private var refreshing = false

    var isActive: Bool {
        Prefs.packShareEnabled && PackSyncLogic.isValidPackCode(Prefs.packCode)
    }

    /// The pack code changed — drop everything learned about the old pack so
    /// stale members don't linger in the menu and the notification snapshot
    /// can't diff one pack against another (a fresh snapshot also means
    /// joining a pack never triggers a notification burst).
    func packChanged() {
        summaries = []
        lastRefresh = nil
        Prefs.packSnapshot = [:]
        Prefs.packSnapshotDay = ""
        refresh(force: true)
    }

    // MARK: - Push (after each completed set)

    func pushToday() {
        guard isActive,
              let url = PackSyncLogic.rpcURL(base: Prefs.packBackendURL, function: "pack_upsert"),
              let body = PackSyncLogic.upsertBody(packCode: Prefs.packCode,
                                                  memberId: Prefs.packMemberId,
                                                  name: Prefs.packResolvedName,
                                                  day: Prefs.dayString(Date()),
                                                  sets: Prefs.setsToday,
                                                  streak: Prefs.currentStreak)
        else { return }
        var req = authed(URLRequest(url: url))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err { NSLog("PackSync: push failed — %@", err.localizedDescription) }
            else if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                NSLog("PackSync: push HTTP %d", http.statusCode)
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh(force: true) } }
            }
        }.resume()
    }

    // MARK: - Refresh (menu open, scheduler fire, after push)

    func refresh(force: Bool = false) {
        guard isActive, !refreshing else { return }
        // Even forced refreshes get a small floor — the Settings pack-code
        // field forces one per edit, which shouldn't turn typing into traffic.
        if let last = lastRefresh, Date().timeIntervalSince(last) < (force ? 2 : 60) { return }
        let today = Prefs.dayString(Date())
        guard let since = PackSyncLogic.dayKeys(endingAt: today, count: 7).first,
              let url = PackSyncLogic.rpcURL(base: Prefs.packBackendURL, function: "pack_fetch"),
              let body = PackSyncLogic.fetchBody(packCode: Prefs.packCode, since: since)
        else { return }
        refreshing = true
        var req = authed(URLRequest(url: url))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let rows = data.flatMap(PackSyncLogic.decodeRows)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshing = false
                    if let err { NSLog("PackSync: fetch failed — %@", err.localizedDescription); return }
                    if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                        NSLog("PackSync: fetch HTTP %d", http.statusCode); return
                    }
                    guard let rows else { NSLog("PackSync: fetch returned undecodable rows"); return }
                    self.lastRefresh = Date()
                    self.apply(rows: rows, today: today)
                }
            }
        }.resume()
    }

    private func apply(rows: [PackSyncLogic.MemberDay], today: String) {
        summaries = PackSyncLogic.summarize(rows: rows, today: today,
                                            selfId: Prefs.packMemberId)
        let previous = Prefs.packSnapshotDay == today ? Prefs.packSnapshot : [:]
        let finished = PackSyncLogic.newlyFinished(previous: previous,
                                                   summaries: summaries,
                                                   selfId: Prefs.packMemberId)
        Prefs.packSnapshotDay = today
        Prefs.packSnapshot = PackSyncLogic.snapshot(of: summaries)
        for event in finished.prefix(3) {   // cap a burst after a long offline gap
            let content = UNMutableNotificationContent()
            content.title = "Pack 💪"
            content.body = "\(event.name) finished a set — \(event.sets) today"
            content.sound = nil
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func authed(_ request: URLRequest) -> URLRequest {
        var req = request
        req.setValue(Prefs.packBackendKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(Prefs.packBackendKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return req
    }
}
