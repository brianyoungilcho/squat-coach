# AGENTS.md — Squat Coach

Guide for AI agents helping a user install, use, or develop Squat Coach — a
native macOS menu-bar app (Swift/SwiftUI, plain `swiftc`, no Xcode project) that
reminds you to do squats every hour and counts your reps with the webcam using
Apple's on-device Vision framework.

## Installing for a user (the most common task)

1. **Requirements**: macOS 13+, Xcode Command Line Tools.
   Check with `xcode-select -p`. If missing, run `xcode-select --install` —
   this pops a **macOS GUI dialog the user must click through** (it renders in
   their OS language). Warn them it's coming, then WAIT until they confirm the
   install finished. It can take several minutes.
2. **Install** (build from source — no Homebrew needed, no Gatekeeper friction):
   ```bash
   git clone https://github.com/brianyoungilcho/squat-coach.git
   cd squat-coach && ./install.sh
   ```
   This compiles a universal binary into `/Applications/Squat Coach.app`,
   ad-hoc signs it, launches it, and registers it to start at login. Never pipe
   curl to bash. (Homebrew path: `brew install --cask --no-quarantine brianyoungilcho/tap/squat-coach`.)
3. **Verify**: `pgrep -f "Squat Coach.app/Contents/MacOS/SquatCoach"` returns a
   PID, and a small **figure icon appears in the menu bar** at the top-right
   (describe it visually — menu-bar strings vary by OS language). If the process
   runs but no icon shows on a notched macOS 26 Mac, the status item was parked
   in the left-of-notch overflow region because it had no persisted position —
   `setupStatusItem` seeds `autosaveName` + a preferred position to avoid this
   (there is **no** per-app menu-bar allow-list in macOS 26; don't look for one).
4. **First run**: macOS prompts once for **Camera** and **Notifications** — the
   user must click Allow. Trigger a set from the menu-bar icon → **Do N squats
   now** (or `kill -USR1 <pid>`). The user stands back until their **hips and
   knees (thighs)** are in frame — feet are not required — and squats.

## Rules

- The camera feed is processed entirely on-device by Vision; **no video is ever
  recorded, saved, or transmitted**. Don't add any network/upload path for frames.
- Pack sharing (Settings → Pack) is **opt-in, off by default**, and posts only the
  display name, squat/set counts, and streak to a user-supplied Slack webhook. Keep
  it that way: never widen what it sends, and never send frames or pose data anywhere.
- Don't disable Gatekeeper globally or change security settings; the
  source-build path needs no Gatekeeper workarounds at all.
- The app is ad-hoc signed (not notarized) — that's intentional. The prebuilt
  zip needs `xattr -dr com.apple.quarantine`; building from source does not.

## How the counting works (so you can reason about "it miscounts")

- Signal = **thigh depth** = `(hipY − kneeY) / standing baseline`, 1.0 standing →
  ~0 deep, auto-calibrated to the user's standing height (camera-angle independent;
  a raw knee angle barely changes head-on, which over-counted in an early version).
- `SquatCounter` is a hysteresis state machine (down < ~0.62 Normal, up on return)
  with a dwell requirement, a 1 s debounce, a dropout reset, and a confidence gate.
- Sensitivity (Easy/Normal/Strict) shifts the threshold. Depth data is logged to
  `/tmp/squatcoach-pose.log` per set — read it to tune against real squats.

## Developing

- **Build + install**: `./build.sh` (universal arm64+x86_64 →
  `/Applications/Squat Coach.app`; version via `SQUAT_COACH_VERSION` env — CI
  derives it from the git tag). No Xcode.
- **Tests**: `./build.sh --test` compiles and runs the standalone (non-XCTest)
  `SquatCounter` and `PackLogic` suites.
- **Release**: push a `vX.Y.Z` tag → `.github/workflows/release.yml` builds,
  zips, publishes a GitHub release, and bumps the Homebrew tap cask.
- **Files**: `Sources/main.swift` (delegate, menu, scheduler, settings, updates),
  `PoseCamera.swift` (capture → Vision → depth), `SquatCounter.swift` (FSM),
  `WorkoutWindow.swift` (pop-to-front window + HUD), `Settings.swift`, `Prefs.swift`.
