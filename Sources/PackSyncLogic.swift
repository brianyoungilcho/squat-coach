import Foundation

/// Pure logic for the pack view: request building, row grouping, pacing dots,
/// and friend-finished detection. No UserDefaults, no networking — everything
/// here is unit-tested headlessly by `./build.sh --test`.
enum PackSyncLogic {
    /// The shared pack backend the app ships with (a free Supabase project).
    /// The key is the *publishable* key — public by design; row access is
    /// bounded by the RLS policies in supabase/schema.sql. Self-hosters can
    /// point the app at their own project via the packBackendURL /
    /// packBackendKey defaults (see README).
    static let defaultBaseURL = "https://dpkyrftbxuhwwwtaftga.supabase.co"
    static let defaultKey = "sb_publishable_xF8Tsxl_TQU04C6ArgRvvw_TFZQ1GUZ"

    struct MemberDay: Codable, Equatable {
        let memberId: String
        let displayName: String
        let day: String        // yyyy-MM-dd, as PostgREST serializes `date`
        let sets: Int
        let streak: Int
        enum CodingKeys: String, CodingKey {
            case memberId = "member_id", displayName = "display_name", day, sets, streak
        }
    }

    enum DayMark: Equatable { case active, todayPending, rest }

    struct MemberSummary: Equatable {
        let id: String
        let name: String
        let setsToday: Int
        let streak: Int
        let marks: [DayMark]   // oldest → today
    }

    // MARK: - Pack codes

    /// Codes are case-insensitive: normalized to uppercase on save so two
    /// friends typing "sqt-bros" and "SQT-BROS" land in the same pack.
    static func normalizedPackCode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Mirrors the server's CHECK constraint so a too-short code fails in the
    /// UI instead of silently 4xx-ing on every push.
    static func isValidPackCode(_ code: String) -> Bool {
        (4...40).contains(code.count)
    }

    // MARK: - Requests (PostgREST RPC — the table itself isn't API-exposed)

    static func rpcURL(base: String, function: String) -> URL? {
        var c = URLComponents(string: base)
        c?.path = "/rest/v1/rpc/\(function)"
        return c?.url
    }

    static func fetchBody(packCode: String, since: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["p_code": packCode, "p_since": since])
    }

    static func upsertBody(packCode: String, memberId: String, name: String,
                           day: String, sets: Int, streak: Int) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "p_code": packCode, "p_member": memberId,
            "p_name": String(name.prefix(40)),   // server bounds display_name at 40
            "p_day": day, "p_sets": sets, "p_streak": streak,
        ])
    }

    static func decodeRows(_ data: Data) -> [MemberDay]? {
        try? JSONDecoder().decode([MemberDay].self, from: data)
    }

    // MARK: - Summarizing

    /// The last `count` day keys ending at `today`, oldest first.
    static func dayKeys(endingAt today: String, count: Int) -> [String] {
        let f = PackLogic.dayFormatter()
        guard let end = f.date(from: today) else { return [today] }
        return (0..<count).reversed().compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: end).map(f.string(from:))
        }
    }

    /// Group raw rows into one summary per member: today's sets, streak, and a
    /// pacing mark per day (filled = did a set that day, matching the streak
    /// semantics). Self first, then most sets today, then name.
    static func summarize(rows: [MemberDay], today: String, days: Int = 5,
                          selfId: String) -> [MemberSummary] {
        let keys = dayKeys(endingAt: today, count: days)
        let byMember = Dictionary(grouping: rows, by: { $0.memberId })
        return byMember.map { id, memberRows in
            let byDay = Dictionary(memberRows.map { ($0.day, $0) },
                                   uniquingKeysWith: { a, _ in a })
            let latest = memberRows.max { $0.day < $1.day }
            let todayRow = byDay[today]
            let marks: [DayMark] = keys.map { key in
                if (byDay[key]?.sets ?? 0) > 0 { return .active }
                return key == today ? .todayPending : .rest
            }
            return MemberSummary(id: id,
                                 name: latest?.displayName ?? "?",
                                 setsToday: todayRow?.sets ?? 0,
                                 streak: (todayRow ?? latest)?.streak ?? 0,
                                 marks: marks)
        }
        .sorted {
            if ($0.id == selfId) != ($1.id == selfId) { return $0.id == selfId }
            if $0.setsToday != $1.setsToday { return $0.setsToday > $1.setsToday }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func menuLine(_ s: MemberSummary, selfId: String) -> String {
        let dots = s.marks.map { mark -> String in
            switch mark {
            case .active: return "●"
            case .todayPending: return "○"
            case .rest: return "·"
            }
        }.joined()
        let you = s.id == selfId ? " (you)" : ""
        return "\(s.name)\(you) — \(s.setsToday) today  \(dots)"
    }

    // MARK: - Friend-finished notifications

    /// Members (other than self) whose today-count increased since the last
    /// snapshot. An empty snapshot means "first fetch of the day" — no events,
    /// so joining a pack never triggers a notification burst.
    static func newlyFinished(previous: [String: Int], summaries: [MemberSummary],
                              selfId: String) -> [(name: String, sets: Int)] {
        guard !previous.isEmpty else { return [] }
        return summaries.filter {
            $0.id != selfId && $0.setsToday > (previous[$0.id] ?? 0)
        }.map { ($0.name, $0.setsToday) }
    }

    static func snapshot(of summaries: [MemberSummary]) -> [String: Int] {
        Dictionary(summaries.map { ($0.id, $0.setsToday) }, uniquingKeysWith: { a, _ in a })
    }
}
