import Foundation

/// Counts squats from a normalized **depth** signal (1.0 standing → 0 deep; see
/// PoseCamera) using a two-state machine with hysteresis, a dwell requirement,
/// debounce, and dropout handling.
///
/// Why each guard exists (all tuned from real logged squats):
///   • hysteresis   — separate down/up thresholds with a dead-band;
///   • dwell        — a transition needs N *consecutive* frames past the
///                    threshold, so a single flickery frame can't tick a rep;
///   • debounce     — a minimum time between reps;
///   • gap reset    — if leg detection drops out briefly, the smoothing buffer
///                    is cleared so stale values can't fire a phantom rep when
///                    tracking returns;
///   • confidence gate — ignore unreliable frames.
/// A rep is counted on the DOWN → UP transition (dropped low, then stood up).
final class SquatCounter {

    struct Config {
        /// Enter DOWN when smoothed depth is below this (fraction of standing height).
        var downEnter: Double = 0.65
        /// Enter UP (and count) when smoothed depth climbs back above this.
        var upEnter: Double = 0.83
        var minConfidence: Double = 0.5
        var minRepInterval: TimeInterval = 1.0
        var smoothingWindow: Int = 5
        /// Consecutive smoothed frames past a threshold required to switch state.
        var dwell: Int = 2
        /// Clear smoothing if this long passes with no valid frame (detection dropout).
        var gapReset: TimeInterval = 0.5
        var resetAfterNoBody: TimeInterval = 12
    }

    enum Phase { case standing, descending, down }

    private(set) var reps = 0
    private(set) var phase: Phase = .standing
    private(set) var smoothedDepth: Double = 1.0

    var config: Config
    var onRep: ((Int) -> Void)?

    private enum State { case up, down }
    private var recent: [Double] = []
    private var state: State = .up
    private var downStreak = 0
    private var upStreak = 0
    private var lastRepTime: TimeInterval = -.infinity
    private var lastValidTime: TimeInterval = -.infinity

    init(config: Config = Config()) { self.config = config }

    /// Feed one frame. `depth`: 1.0 = standing, → 0 = deep squat.
    func update(depth: Double, confidence: Double, time: TimeInterval) {
        guard confidence >= config.minConfidence else {
            if time - lastValidTime > config.resetAfterNoBody { softReset() }
            return
        }
        // Detection dropout: don't blend pre- and post-gap frames.
        if time - lastValidTime > config.gapReset {
            recent.removeAll(); downStreak = 0; upStreak = 0
        }
        lastValidTime = time

        recent.append(depth)
        if recent.count > config.smoothingWindow { recent.removeFirst() }
        let d = recent.reduce(0, +) / Double(recent.count)
        smoothedDepth = d

        switch state {
        case .up:
            downStreak = d < config.downEnter ? downStreak + 1 : 0
            phase = d < config.upEnter ? .descending : .standing
            if downStreak >= config.dwell { state = .down; phase = .down; upStreak = 0 }
        case .down:
            phase = .down
            upStreak = d > config.upEnter ? upStreak + 1 : 0
            if upStreak >= config.dwell {
                if time - lastRepTime >= config.minRepInterval {
                    reps += 1
                    lastRepTime = time
                    onRep?(reps)
                }
                state = .up
                downStreak = 0
            }
        }
    }

    func reset() { reps = 0; softReset() }

    private func softReset() {
        recent.removeAll()
        state = .up
        phase = .standing
        smoothedDepth = 1.0
        downStreak = 0
        upStreak = 0
        lastRepTime = -.infinity
    }
}
