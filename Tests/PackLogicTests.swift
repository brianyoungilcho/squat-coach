import Foundation

// Standalone test runner for PackLogic (compiled with Sources/PackLogic.swift
// by `./build.sh --test`; no XCTest/Xcode). Exits non-zero on failure.
// Everything tested here is pure — no UserDefaults, no network.

private var failures = 0
private func check(_ cond: Bool, _ msg: String) {
    print(cond ? "  ok  — \(msg)" : "  FAIL — \(msg)")
    if !cond { failures += 1 }
}

print("PackLogic tests (pack sharing)")

// 1. dayLog: today's count is recorded / overwritten.
do {
    let log = PackLogic.updatedDayLog(["2026-07-08": 3], today: "2026-07-09", setsToday: 1)
    check(log == ["2026-07-08": 3, "2026-07-09": 1], "records today alongside yesterday → \(log)")
    let bumped = PackLogic.updatedDayLog(log, today: "2026-07-09", setsToday: 2)
    check(bumped["2026-07-09"] == 2, "second set overwrites today's count → \(bumped["2026-07-09"] ?? -1)")
}

// 2. dayLog: entries older than keepDays are pruned; the boundary day survives.
do {
    let old = ["2026-06-09": 5, "2026-06-10": 4, "2026-07-09": 1]
    let log = PackLogic.updatedDayLog(old, today: "2026-07-09", setsToday: 1, keepDays: 30)
    check(log["2026-06-09"] == nil, "day 31 is pruned")
    check(log["2026-06-10"] == 4, "day 30 (boundary) is kept")
}

// 3. dayLog: prune crosses month/year boundaries correctly (lexical == chronological).
do {
    let log = PackLogic.updatedDayLog(["2025-12-31": 2], today: "2026-01-02", setsToday: 1, keepDays: 3)
    check(log["2025-12-31"] == 2, "year boundary: 2 days back is kept with keepDays 3")
    let pruned = PackLogic.updatedDayLog(["2025-12-30": 2], today: "2026-01-02", setsToday: 1, keepDays: 3)
    check(pruned["2025-12-30"] == nil, "year boundary: 3 days back is pruned with keepDays 3")
}

// 4. Digest gating: once per day, only after 06:00, only when enabled.
do {
    check(PackLogic.shouldPostDigest(enabled: true, lastDigestDay: "2026-07-08", today: "2026-07-09", hour: 9),
          "new day + morning + enabled → post")
    check(!PackLogic.shouldPostDigest(enabled: true, lastDigestDay: "2026-07-09", today: "2026-07-09", hour: 9),
          "already posted today → skip")
    check(!PackLogic.shouldPostDigest(enabled: true, lastDigestDay: "2026-07-08", today: "2026-07-09", hour: 3),
          "3 AM → skip (waits for 06:00)")
    check(!PackLogic.shouldPostDigest(enabled: false, lastDigestDay: "2026-07-08", today: "2026-07-09", hour: 9),
          "sharing disabled → skip")
    check(PackLogic.shouldPostDigest(enabled: true, lastDigestDay: "", today: "2026-07-09", hour: 6),
          "never posted before + exactly 06:00 → post")
}

// 5. Message copy: pluralization and content.
do {
    let one = PackLogic.setMessage(name: "Brian", reps: 30, setsToday: 1, streak: 12)
    check(one.contains("1 set today") && !one.contains("1 sets"), "singular set → \(one)")
    let many = PackLogic.setMessage(name: "Brian", reps: 30, setsToday: 3, streak: 12)
    check(many.contains("Brian") && many.contains("30 squats") && many.contains("3 sets today")
          && many.contains("12-day streak"), "set message carries name/reps/sets/streak → \(many)")
    let digest = PackLogic.digestMessage(name: "Yuna", yesterdaySets: 4)
    check(digest.contains("Yesterday") && digest.contains("Yuna") && digest.contains("4 sets"),
          "digest message → \(digest)")
    let zero = PackLogic.digestMessage(name: "Dan", yesterdaySets: 0)
    check(zero.contains("0 sets"), "zero-day digest still posts the honest count → \(zero)")
}

// 6. Webhook payload is valid JSON of the exact shape Slack expects.
do {
    let text = "🏋️ test — with \"quotes\" and a\nnewline"
    if let data = PackLogic.webhookPayload(text: text),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        check(obj == ["text": text], "payload round-trips through JSON → \(obj)")
    } else {
        check(false, "payload failed to encode/decode")
    }
}

print(failures == 0 ? "\nALL TESTS PASSED ✅" : "\n\(failures) TEST(S) FAILED ❌")
exit(failures == 0 ? 0 : 1)
