import Foundation

// Standalone test runner for PackSyncLogic (compiled with Sources/PackLogic.swift
// + Sources/PackSyncLogic.swift by `./build.sh --test`; no XCTest). Exits
// non-zero on failure. Everything tested here is pure.

private var failures = 0
private func check(_ cond: Bool, _ msg: String) {
    print(cond ? "  ok  — \(msg)" : "  FAIL — \(msg)")
    if !cond { failures += 1 }
}

typealias Row = PackSyncLogic.MemberDay

print("PackSyncLogic tests (pack view)")

// 1. dayKeys: oldest-first window ending today, across a month boundary.
do {
    let keys = PackSyncLogic.dayKeys(endingAt: "2026-07-02", count: 5)
    check(keys == ["2026-06-28", "2026-06-29", "2026-06-30", "2026-07-01", "2026-07-02"],
          "5-day window crosses the month boundary → \(keys)")
}

// 2. summarize: grouping, dots, today counts, sorting (self first, then sets).
do {
    let rows = [
        Row(memberId: "me", displayName: "Brian", day: "2026-07-09", sets: 2, streak: 12),
        Row(memberId: "me", displayName: "Brian", day: "2026-07-08", sets: 5, streak: 11),
        Row(memberId: "yuna", displayName: "Yuna", day: "2026-07-09", sets: 3, streak: 7),
        Row(memberId: "yuna", displayName: "Yuna", day: "2026-07-07", sets: 4, streak: 5),
        Row(memberId: "dan", displayName: "Dan", day: "2026-07-06", sets: 1, streak: 1),
    ]
    let s = PackSyncLogic.summarize(rows: rows, today: "2026-07-09", days: 5, selfId: "me")
    check(s.count == 3, "3 members → \(s.count)")
    check(s[0].id == "me", "self sorts first even with fewer sets → \(s[0].id)")
    check(s[1].id == "yuna" && s[1].setsToday == 3, "then most sets today → \(s[1].id)")
    check(s[2].id == "dan" && s[2].setsToday == 0, "quiet member shows 0 today")
    check(s[0].marks == [.rest, .rest, .rest, .active, .active], "self dots: 2 active days")
    check(s[1].marks == [.rest, .rest, .active, .rest, .active], "yuna dots: gap day is rest")
    check(s[2].marks == [.rest, .active, .rest, .rest, .todayPending], "dan: today pending, not rest")
}

// 3. summarize: display name follows the LATEST row (renames stick).
do {
    let rows = [
        Row(memberId: "x", displayName: "Old Name", day: "2026-07-07", sets: 1, streak: 1),
        Row(memberId: "x", displayName: "New Name", day: "2026-07-09", sets: 1, streak: 2),
    ]
    let s = PackSyncLogic.summarize(rows: rows, today: "2026-07-09", selfId: "me")
    check(s[0].name == "New Name", "latest display name wins → \(s[0].name)")
}

// 4. menuLine formatting.
do {
    let s = PackSyncLogic.MemberSummary(id: "me", name: "Brian", setsToday: 2, streak: 12,
                                        marks: [.active, .rest, .active, .active, .todayPending])
    let line = PackSyncLogic.menuLine(s, selfId: "me")
    check(line == "Brian (you) — 2 today  ●·●●○", "menu line → \(line)")
}

// 5. newlyFinished: increases only, self excluded, empty snapshot = no burst.
do {
    let s = [
        PackSyncLogic.MemberSummary(id: "me", name: "Brian", setsToday: 3, streak: 1, marks: []),
        PackSyncLogic.MemberSummary(id: "yuna", name: "Yuna", setsToday: 4, streak: 1, marks: []),
        PackSyncLogic.MemberSummary(id: "dan", name: "Dan", setsToday: 1, streak: 1, marks: []),
    ]
    let events = PackSyncLogic.newlyFinished(previous: ["me": 1, "yuna": 3, "dan": 1],
                                             summaries: s, selfId: "me")
    check(events.count == 1 && events[0].name == "Yuna" && events[0].sets == 4,
          "only Yuna increased (self excluded) → \(events)")
    check(PackSyncLogic.newlyFinished(previous: [:], summaries: s, selfId: "me").isEmpty,
          "empty snapshot (first fetch of day) → no notification burst")
    let newMember = PackSyncLogic.newlyFinished(previous: ["me": 1], summaries: s, selfId: "me")
    check(newMember.count == 2, "members not in the snapshot count as 0 → both notify")
}

// 6. Pack-code generation: format, alphabet, entropy sanity, uniqueness.
do {
    let code = PackSyncLogic.generatePackCode()
    check(code.count == 18 && code.hasPrefix("SQT"), "canonical form: SQT + 15 chars → \(code)")
    let alphabet = Set(PackSyncLogic.codeAlphabet)
    check(code.dropFirst(3).allSatisfy { alphabet.contains($0) },
          "body uses only the Crockford alphabet")
    check(!code.contains("I") && !code.contains("L") && !code.contains("O") && !code.contains("U"),
          "no I/L/O/U (ambiguity + obscenity exclusions)")
    check(PackSyncLogic.codeAlphabet.count == 32, "32-symbol alphabet = 5 bits/char (75 bits total)")
    let sample = Set((0..<1000).map { _ in PackSyncLogic.generatePackCode() })
    check(sample.count == 1000, "1000 generated codes are all distinct")
    check(PackSyncLogic.isValidPackCode(code), "generated codes pass validation")
}

// 7. Decode-lenient normalization (Crockford): case, separators, confusables.
do {
    check(PackSyncLogic.normalizedPackCode("  sqt-k7mp2-9wxtv-3rhbd \n") == "SQTK7MP29WXTV3RHBD",
          "display form normalizes to canonical (case, hyphens, whitespace)")
    check(PackSyncLogic.normalizedPackCode("SQT KOMP2") == "SQTK0MP2", "O folds to 0")
    check(PackSyncLogic.normalizedPackCode("sqt-lian1") == "SQT11AN1", "L and I fold to 1")
    let code = PackSyncLogic.generatePackCode()
    check(PackSyncLogic.normalizedPackCode(PackSyncLogic.displayPackCode(code)) == code,
          "normalize(display(code)) round-trips to canonical")
    check(PackSyncLogic.normalizedPackCode(code) == code, "normalization is idempotent on canonical")
    check(PackSyncLogic.isValidPackCode("SQTS"), "4 chars is valid (server CHECK lower bound)")
    check(!PackSyncLogic.isValidPackCode("SQT"), "3 chars is rejected")
    check(!PackSyncLogic.isValidPackCode(String(repeating: "X", count: 41)), "41 chars is rejected")
}

// 8. Display chunking and the invite message.
do {
    check(PackSyncLogic.displayPackCode("SQTK7MP29WXTV3RHBD") == "SQT-K7MP2-9WXTV-3RHBD",
          "canonical renders as SQT-XXXXX-XXXXX-XXXXX")
    check(PackSyncLogic.displayPackCode("MY-CUSTOM-CODE") == "MY-CUSTOM-CODE",
          "non-generated codes pass through untouched")
    let msg = PackSyncLogic.inviteMessage(code: "SQTK7MP29WXTV3RHBD")
    check(msg.contains("SQT-K7MP2-9WXTV-3RHBD") && msg.contains("github.com/brianyoungilcho/squat-coach"),
          "invite carries the display code and an install link")
}

// 9. RPC request builders: URL shape, body keys, name truncation.
do {
    let url = PackSyncLogic.rpcURL(base: "https://x.supabase.co", function: "pack_fetch")
    check(url?.absoluteString == "https://x.supabase.co/rest/v1/rpc/pack_fetch",
          "rpc URL → \(url?.absoluteString ?? "nil")")
    let fetch = PackSyncLogic.fetchBody(packCode: "SQT-BROS", since: "2026-07-03")
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    check(fetch == ["p_code": "SQT-BROS", "p_since": "2026-07-03"], "fetch body args")
    let body = PackSyncLogic.upsertBody(packCode: "SQT-BROS", memberId: "abc",
                                        name: String(repeating: "n", count: 60),
                                        day: "2026-07-09", sets: 2, streak: 12)
    let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(obj?["p_code"] as? String == "SQT-BROS" && obj?["p_sets"] as? Int == 2
          && obj?["p_member"] as? String == "abc", "upsert body carries all fields")
    check((obj?["p_name"] as? String)?.count == 40, "display name truncated to the server's 40-char bound")
}

// 10. Row decoding matches PostgREST's JSON shape (rpc returns the same columns).
do {
    let json = """
    [{"member_id":"abc","display_name":"Yuna","day":"2026-07-09","sets":3,"streak":7}]
    """.data(using: .utf8)!
    let rows = PackSyncLogic.decodeRows(json)
    check(rows == [Row(memberId: "abc", displayName: "Yuna", day: "2026-07-09", sets: 3, streak: 7)],
          "decodes PostgREST snake_case rows")
}

print(failures == 0 ? "\nALL TESTS PASSED ✅" : "\n\(failures) TEST(S) FAILED ❌")
exit(failures == 0 ? 0 : 1)
