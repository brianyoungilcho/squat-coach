import Darwin
import Foundation

@main
struct LogicTests {
    private static var failures = 0

    static func main() async {
        testReminderCadence()
        testSquatCounter()
        testHistory()
        testInviteParser()
        testUpdaterParsing()
        await testOutbox()

        if failures == 0 {
            print("ALL LOGIC TESTS PASSED")
            exit(0)
        }
        print("\(failures) LOGIC TEST(S) FAILED")
        exit(1)
    }

    private static func testReminderCadence() {
        let first = Date(timeIntervalSince1970: 1_000)
        check(
            ReminderSchedule.nextFireDate(
                now: first.addingTimeInterval(1),
                interval: 45 * 60,
                previousScheduledFire: first
            ).timeIntervalSince(first) == 45 * 60,
            "45-minute cadence remains 45 minutes"
        )
        check(
            ReminderSchedule.nextFireDate(
                now: first.addingTimeInterval(1),
                interval: 90 * 60,
                previousScheduledFire: first
            ).timeIntervalSince(first) == 90 * 60,
            "90-minute cadence remains 90 minutes"
        )
        let delayed = ReminderSchedule.nextFireDate(
            now: first.addingTimeInterval(200 * 60),
            interval: 45 * 60,
            previousScheduledFire: first
        )
        check(
            delayed.timeIntervalSince(first) == 225 * 60,
            "delayed timer skips missed cadence points"
        )
    }

    private static func testSquatCounter() {
        let deepSquat = [
            1.0, 1.0, 0.90, 0.78, 0.66, 0.55, 0.47, 0.45,
            0.52, 0.66, 0.80, 0.90, 0.97, 1.0, 1.0, 1.0,
        ]
        let counter = SquatCounter()
        var time = 0.0
        for _ in 0..<30 { feed(counter, deepSquat, time: &time) }
        check(counter.reps == 30, "30 deep squats count exactly")

        let dropout = SquatCounter()
        time = 0
        feed(dropout, [1.0, 1.0, 0.82, 0.62, 0.48, 0.44], time: &time)
        dropout.missingObservation(time: time + 1.0)
        time += 1.1
        feed(dropout, [1.0, 1.0, 1.0], time: &time)
        check(dropout.reps == 0, "short body dropout cancels an ambiguous rep")

        let longDropout = SquatCounter()
        time = 0
        feed(longDropout, [1.0, 1.0, 0.82, 0.62, 0.48, 0.44], time: &time)
        longDropout.missingObservation(
            time: time + longDropout.config.resetAfterNoBody + 0.1
        )
        time += longDropout.config.resetAfterNoBody + 0.2
        feed(longDropout, [1.0, 1.0, 1.0, 1.0], time: &time)
        check(longDropout.reps == 0, "long body dropout cannot finish a stale rep")
        if case .standing = longDropout.phase {
            check(true, "long body dropout resets phase")
        } else {
            check(false, "long body dropout resets phase")
        }
    }

    private static func testHistory() {
        let log = HistoryLogic.updatedDayLog(
            ["2026-07-08": 3],
            today: "2026-07-09",
            setsToday: 1
        )
        check(
            log == ["2026-07-08": 3, "2026-07-09": 1],
            "history records today"
        )
        let pruned = HistoryLogic.updatedDayLog(
            ["2025-12-30": 2],
            today: "2026-01-02",
            setsToday: 1,
            keepDays: 3
        )
        check(pruned["2025-12-30"] == nil, "history retention crosses years")
    }

    private static func testInviteParser() {
        let token = String(repeating: "a", count: 43)
        check(
            PackInviteParser.token(from: "squatcoach://join/\(token)") == token,
            "deep-link invite parses"
        )
        check(
            PackInviteParser.token(from: "short") == nil,
            "short invite is rejected"
        )
    }

    private static func testUpdaterParsing() {
        check(
            UpdaterLogic.isNewer(latest: "0.10.0", current: "0.9.0"),
            "versions compare numerically"
        )
        check(
            !UpdaterLogic.isTrustedDownloadURL(
                URL(string: "https://github.com.evil.com/update.zip")!
            ),
            "update host spoofing is rejected"
        )
    }

    private static func testOutbox() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let event = PendingWorkoutEvent(
            id: UUID(),
            packId: UUID(),
            userId: UUID(),
            reps: 30,
            setsToday: 1,
            streak: 2,
            localDay: "2026-07-12",
            completedAt: Date(timeIntervalSince1970: 1_000)
        )
        let outbox = SocialOutbox(fileURL: file)
        do {
            try await outbox.enqueue(event)
            try await outbox.enqueue(event)
            let queued = await outbox.all()
            check(queued.count == 1, "outbox enqueue is idempotent")
            let restored = SocialOutbox(fileURL: file)
            let restoredEvents = await restored.all()
            check(restoredEvents == [event], "outbox survives restart")
            try await restored.removeAll(packId: event.packId)
            let afterPurge = await restored.all()
            check(afterPurge.isEmpty, "outbox purges departed Pack events")
        } catch {
            check(false, "outbox persists without error: \(error)")
        }
    }

    private static func feed(
        _ counter: SquatCounter,
        _ depths: [Double],
        time: inout Double
    ) {
        for depth in depths {
            counter.update(depth: depth, confidence: 0.9, time: time)
            time += 0.1
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("ok — \(message)")
        } else {
            failures += 1
            print("FAIL — \(message)")
        }
    }
}
