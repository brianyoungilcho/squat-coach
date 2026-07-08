import Foundation

/// Counts squats from a normalized **depth** signal (1.0 standing → 0 deep; see
/// PoseCamera) using a two-state machine that is **relative to the user's own
/// standing height**, with a prominence gate, dwell, debounce, and dropout handling.
///
/// Why relative (this is the load-bearing design choice):
///   An earlier version counted a rep only when smoothed depth climbed back above a
///   FIXED absolute threshold (e.g. 0.88). But the standing baseline can drift or
///   latch high, so "standing" ends up reading ~0.82 and the fixed up-gate becomes
///   physically unreachable — the machine sticks in `.down` and silently drops reps
///   (a real logged session missed ~38% this way, and Easy mode — which pushed the
///   up-gate to 0.88 — counted almost nothing). The fix: learn the session's actual
///   standing level (`standingRef`) and judge every rep against IT:
///     • arm the descent when depth falls `armFrac` below standingRef;
///     • count when depth recovers `recoverFrac` of the way back up from *this rep's
///       own bottom* — so a genuine stand-up ALWAYS clears it, whatever the scale;
///     • require the rep's prominence (standingRef − bottom) to exceed
///       `minPromFrac × standingRef` — a scale-relative "went deep enough" gate that
///       rejects bobs/jitter without any absolute number.
///
/// The remaining guards (all tuned from real logged squats):
///   • dwell        — a transition needs N consecutive frames past the threshold, so
///                    a single flickery frame can't tick a rep;
///   • debounce     — a minimum time between reps;
///   • gap reset    — if leg detection drops out briefly, the smoothing buffer is
///                    cleared so stale values can't fire a phantom rep on return;
///   • confidence gate — ignore unreliable frames.
/// A rep is counted on the DOWN → UP transition (dropped low, then stood back up).
final class SquatCounter {

    struct Config {
        /// Arm the descent when smoothed depth falls below `armFrac × standingRef`
        /// (i.e. this fraction of the way down from the user's own standing height).
        var armFrac: Double = 0.88
        /// Count once smoothed depth has climbed this fraction of the way back up
        /// from the rep's own minimum toward standingRef. Fires mid-ascent (fast),
        /// not at a peak that may never arrive.
        var recoverFrac: Double = 0.55
        /// The rep must span at least this fraction of standingRef in depth (anti-bob
        /// prominence gate). This is the Easy/Normal/Strict knob — "how deep counts".
        var minPromFrac: Double = 0.24
        var minConfidence: Double = 0.5
        var minRepInterval: TimeInterval = 1.0
        var smoothingWindow: Int = 5
        /// Consecutive smoothed frames past a threshold required to switch state.
        var dwell: Int = 2
        /// Clear smoothing if this long passes with no valid frame (detection dropout).
        var gapReset: TimeInterval = 0.5
        var resetAfterNoBody: TimeInterval = 12
        /// standingRef EWMA: rise fast toward a higher standing reading, decay slowly.
        /// Asymmetry means a squat (depth ≪ standingRef) can't drag the reference down.
        var standingRise: Double = 0.5
        var standingDecay: Double = 0.02
    }

    enum Phase { case standing, descending, down }

    private(set) var reps = 0
    private(set) var phase: Phase = .standing
    private(set) var smoothedDepth: Double = 1.0
    /// The learned standing-height reference the counter judges reps against.
    private(set) var standingRef: Double = 1.0

    var config: Config
    var onRep: ((Int) -> Void)?

    private enum State { case up, down }
    private var recent: [Double] = []
    private var state: State = .up
    private var seeded = false
    private var repMin: Double = 1.0
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

        // Seed the standing reference from the first valid frame (the set starts with
        // the user standing) so it's anchored immediately rather than decaying in.
        if !seeded { standingRef = d; seeded = true }

        switch state {
        case .up:
            // Learn the habitual standing height: rise fast, decay slow.
            let rate = d > standingRef ? config.standingRise : config.standingDecay
            standingRef += rate * (d - standingRef)

            let armThreshold = standingRef * config.armFrac
            downStreak = d < armThreshold ? downStreak + 1 : 0
            phase = d < armThreshold ? .descending : .standing
            if downStreak >= config.dwell {
                state = .down; phase = .down; upStreak = 0; repMin = d
            }
        case .down:
            phase = .down
            if d < repMin { repMin = d }               // track this rep's true bottom
            let prominence = standingRef - repMin
            let target = repMin + config.recoverFrac * prominence
            let recovered = d >= target && prominence >= config.minPromFrac * standingRef
            upStreak = recovered ? upStreak + 1 : 0
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
        standingRef = 1.0
        seeded = false
        repMin = 1.0
        downStreak = 0
        upStreak = 0
        lastRepTime = -.infinity
    }
}
