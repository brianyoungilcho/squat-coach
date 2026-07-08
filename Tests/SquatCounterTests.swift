import Foundation

// Standalone test runner (compiled with Sources/SquatCounter.swift by
// `./build.sh --test`; no XCTest/Xcode). Exits non-zero on failure.
// Signal convention: depth 1.0 = standing, → 0 = deep squat.

private var failures = 0
private func check(_ cond: Bool, _ msg: String) {
    print(cond ? "  ok  — \(msg)" : "  FAIL — \(msg)")
    if !cond { failures += 1 }
}

// A clear, deep squat: standing → ~0.45 → standing (matches real logged depth),
// with settle frames so the smoothing + dwell cross both thresholds.
private let deepSquat  = [1.0, 1.0, 0.90, 0.78, 0.66, 0.55, 0.47, 0.45, 0.52, 0.66, 0.80, 0.90, 0.97, 1.0, 1.0, 1.0]
// A tiny bob / camera jitter that must NOT count (never gets deep).
private let tinyBob    = [1.0, 1.0, 0.95, 0.91, 0.88, 0.90, 0.94, 0.98, 1.0, 1.0]
// A shallow dip to ~0.72 — never deep enough for Strict.
private let shallowDip = [1.0, 1.0, 0.90, 0.84, 0.78, 0.74, 0.72, 0.75, 0.82, 0.90, 0.97, 1.0, 1.0, 1.0]

private func feed(_ c: SquatCounter, _ depths: [Double],
                  t: inout Double, dt: Double = 0.1, conf: Double = 0.9) {
    for d in depths { c.update(depth: d, confidence: conf, time: t); t += dt }
}

print("SquatCounter tests (depth signal)")

// 1. 30 clean deep squats → exactly 30.
do {
    let c = SquatCounter(); var t = 0.0
    for _ in 0..<30 { feed(c, deepSquat, t: &t) }
    check(c.reps == 30, "30 deep squats → \(c.reps) (expect 30)")
}

// 2. Standing still → 0.
do {
    let c = SquatCounter(); var t = 0.0
    feed(c, Array(repeating: 1.0, count: 60), t: &t)
    check(c.reps == 0, "standing still → \(c.reps) (expect 0)")
}

// 3. THE sensitivity fix: small bobs / jitter never count.
do {
    let c = SquatCounter(); var t = 0.0
    for _ in 0..<10 { feed(c, tinyBob, t: &t) }
    check(c.reps == 0, "tiny bobs → \(c.reps) (expect 0)")
}

// 4. Low-confidence frames are gated out.
do {
    let c = SquatCounter(); var t = 0.0
    feed(c, deepSquat, t: &t, conf: 0.2)
    check(c.reps == 0, "low-confidence squat → \(c.reps) (expect 0)")
}

// 5. Back-to-back deep squats each count.
do {
    let c = SquatCounter(); var t = 0.0
    for _ in 0..<3 { feed(c, deepSquat, t: &t, dt: 0.08) }
    check(c.reps == 3, "3 back-to-back deep squats → \(c.reps) (expect 3)")
}

// 6. reset() zeroes the count.
do {
    let c = SquatCounter(); var t = 0.0
    feed(c, deepSquat, t: &t)
    c.reset()
    check(c.reps == 0, "reset() → \(c.reps) (expect 0)")
}

// 7. Strict sensitivity requires real depth: a shallow dip never counts.
do {
    var cfg = SquatCounter.Config(); cfg.downEnter = 0.58; cfg.upEnter = 0.76
    let c = SquatCounter(config: cfg); var t = 0.0
    for _ in 0..<3 { feed(c, shallowDip, t: &t) }
    check(c.reps == 0, "shallow dips on Strict → \(c.reps) (expect 0)")
}

print(failures == 0 ? "\nALL TESTS PASSED ✅" : "\n\(failures) TEST(S) FAILED ❌")
exit(failures == 0 ? 0 : 1)
