# Squat Coach — status

Native macOS menu-bar app: pops up every hour, opens the webcam, and counts
squats using Apple's Vision framework. 100% Apple frameworks, no Xcode, fully
on-device.

## Working (2026-07-08)
- Built with `swiftc` + `build.sh` (no Xcode), ad-hoc signed, at `/Applications/Squat Coach.app`.
- Menu-bar app (no Dock icon), hourly reminder, assertive pop-to-front window,
  live camera + skeleton, streak, sensitivity + interval + target settings.
- **Counting verified against real logged squats: 5/5, ~2 s cadence, no doubles/misses.**

## Counting design (v3 — thigh depth)
- Signal = `(hipY − kneeY) / standing baseline` → 1.0 standing, ~0 deep. Auto-calibrated
  to the user's standing height. Needs only **hips + knees** in frame (no ankles) → works
  right at a laptop.
- FSM: down at depth < 0.62 (Normal), count on down→up. Guards: hysteresis, dwell (2 frames),
  1 s debounce, dropout reset, confidence ≥ 0.5, 5-frame smoothing.
- Sensitivity Easy/Normal/Strict = downEnter 0.70/0.62/0.54.
- History: knee-angle (over-counted head-on) → hip-ankle depth (needed feet in frame) →
  hip-knee thigh depth (current, laptop-friendly).

## Use
- Menu-bar 🏋️ icon → "Do 30 squats now" (or hourly). Stand back so the depth meter appears.
- `/tmp/squatcoach-pose.log` records depth/rawT/h0/conf/reps per set (for tuning).
- `kill -USR1 $(pgrep -f 'Squat Coach.app/Contents/MacOS/SquatCoach')` fires a set now.
- Tests: `./build.sh --test`.

## Deferred / optional
- git repo init + first commit (not done; local-only intended).
- Open-source repo + Homebrew cask + notarization (Phase 2).
- Custom app icon, form-quality coaching, history charts.
