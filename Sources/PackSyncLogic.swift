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
    //
    // Codes are machine-generated bearer secrets, not user-picked names — two
    // strangers typing the same obvious word must never collide into one pack,
    // and the join endpoint is effectively unthrottled, so guessing has to be
    // infeasible on entropy alone. Design (per Crockford Base32 / RFC 8628 /
    // ULID practice): 15 random chars of the Crockford alphabet = 75 bits,
    // "SQT" brand prefix (zero entropy), displayed in 5-char hyphen chunks,
    // decode-lenient on input (case-folded, hyphens/whitespace ignored,
    // O→0 and I/L→1).

    /// Crockford Base32: no I, L, O (look like 1/0) and no U (accidental
    /// obscenity). 32 symbols = 5 bits per character.
    static let codeAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let codeAlphabetSet = Set(codeAlphabet)

    /// A fresh pack code in canonical (hyphen-free) form, e.g.
    /// "SQTK7MP29WXTV3RHBD". SystemRandomNumberGenerator is cryptographically
    /// secure, so 15 alphabet chars = 75 bits against blind guessing.
    static func generatePackCode() -> String {
        "SQT" + String((0..<15).map { _ in codeAlphabet.randomElement()! })
    }

    /// Decode-lenient normalization for anything typed or pasted: uppercase,
    /// fold the confusables the alphabet excludes (O→0, I/L→1), then keep ONLY
    /// ASCII A-Z/0-9 — hyphens, whitespace, and the invisible junk rich-text
    /// sources smuggle in (zero-width spaces, directional marks) all drop out.
    /// Idempotent over both the canonical and display forms of generated codes.
    static func normalizedPackCode(_ raw: String) -> String {
        String(raw.uppercased().compactMap { ch -> Character? in
            switch ch {
            case "O": return "0"
            case "I", "L": return "1"
            default:
                guard let ascii = ch.asciiValue else { return nil }
                return (0x30...0x39).contains(ascii) || (0x41...0x5A).contains(ascii) ? ch : nil
            }
        })
    }

    /// True only for codes in the generated shape — the Join field accepts
    /// nothing else, so hand-invented low-entropy codes (two strangers typing
    /// the same obvious word) can't come back in through the front door.
    static func isGeneratedCode(_ code: String) -> Bool {
        code.count == 18 && code.hasPrefix("SQT")
            && code.dropFirst(3).allSatisfy { codeAlphabetSet.contains($0) }
    }

    /// Human form of a generated code: "SQT-K7MP2-9WXTV-3RHBD". Codes that
    /// aren't ours (self-hosters, custom) pass through untouched.
    static func displayPackCode(_ code: String) -> String {
        guard code.count == 18, code.hasPrefix("SQT") else { return code }
        let body = Array(code.dropFirst(3))
        return "SQT-" + stride(from: 0, to: body.count, by: 5)
            .map { String(body[$0..<min($0 + 5, body.count)]) }
            .joined(separator: "-")
    }

    /// The message "Copy invite" puts on the clipboard — code plus a way in
    /// for friends who don't have the app yet.
    static func inviteMessage(code: String) -> String {
        """
        Join my Squat Coach pack 🏋️
        Pack code: \(displayPackCode(code))
        Get the app: https://github.com/brianyoungilcho/squat-coach#install
        Then: menu bar icon → Settings… → Pack → paste the code into “Join”.
        """
    }

    /// Mirrors the server's CHECK constraint so a bad code fails in the UI
    /// instead of silently 4xx-ing on every push.
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
