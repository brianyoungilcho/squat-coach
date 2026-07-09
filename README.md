# Squat Coach

A tiny macOS menu-bar app that reminds you to do squats every hour and **counts
them with your webcam** — no Xcode, no third-party libraries, and your camera
never leaves your Mac.

It's the Claude Dash pattern (Swift + `swiftc` + a build script) with an added
camera → Apple Vision → rep-counter pipeline.

## What it does

- Lives in the menu bar (🏋️ figure icon), no Dock icon.
- Every hour (configurable), pops a window to the front and posts a notification.
- Opens your webcam, draws a live skeleton, and counts squats to a target (default 30).
- Hit the target → logs the set and advances a daily 🔥 streak. **Skip** any time.
- **Pack (optional, off by default):** post finished sets to a shared Slack channel
  so friends can keep each other accountable — see [Pack](#pack--squat-with-friends-optional).
- 100% on-device counting: Apple's Vision framework does the pose detection locally.
  No video is recorded, saved, or sent anywhere — with Pack sharing on, only your
  display name, set counts, and streak are posted.

## Requirements

- macOS 13+ (built/tested on macOS 26).
- **Xcode Command Line Tools only** (`xcode-select --install`) — no Xcode.app needed.

## Install

Requires macOS 13+ and the Xcode Command Line Tools
(`xcode-select --install` — one-time, no full Xcode needed).

### Homebrew (recommended)

```bash
brew install --cask --no-quarantine brianyoungilcho/tap/squat-coach
```

`--no-quarantine` because the app is ad-hoc signed, not notarized. Upgrade later
with `brew upgrade --cask squat-coach`, or from inside the app: **Check for
Updates… → Install and Relaunch** downloads the new version and swaps it in
place. (In-app updates don't update Homebrew's own bookkeeping — a later
`brew upgrade` just reinstalls the version you already have, which is harmless.)
On first launch, allow **Camera** and **Notifications** when macOS asks —
pose detection runs entirely on-device; no video is recorded, saved, or sent.

### Prebuilt zip (manual)

From [Releases](https://github.com/brianyoungilcho/squat-coach/releases): unzip,
**drag `Squat Coach.app` into `/Applications`** (required — running from Downloads
breaks start-at-login via App Translocation), then clear quarantine:
`xattr -dr com.apple.quarantine "/Applications/Squat Coach.app"` and open it.

### Build from source (no Gatekeeper friction)

```bash
git clone https://github.com/brianyoungilcho/squat-coach.git && cd squat-coach && ./install.sh
```

Builds into `/Applications/Squat Coach.app`, launches it, and registers a login
item. Re-run `./install.sh` after any edit to rebuild and relaunch.

## Use

- Click the menu-bar icon → **Do 30 squats now** (or wait for the hourly reminder).
- Stand back so your **hips and knees (thighs)** are in frame, then squat — no need
  to fit your feet in, so it works right at a laptop.
- Change the interval / target / sensitivity / rep-sound from the same menu, or in
  **Settings**.
- `kill -USR1 $(pgrep -f 'Squat Coach.app/Contents/MacOS/SquatCoach')` triggers a
  reminder immediately (handy for scripting a "remind me now").

## Pack — squat with friends (optional)

Invite friends or colleagues into a shared Slack channel and every finished set
posts a one-liner ("🏋️ Brian finished a set — 30 squats · 2 sets today · 🔥
12-day streak"), plus a short morning recap of yesterday. Everyone sees everyone
pacing; nobody has to ask. Off by default.

**Setup (one person, ~2 minutes):**

1. Create the channel (e.g. `#squat-pack`) and invite the pack.
2. Create the webhook at [api.slack.com/apps](https://api.slack.com/apps) →
   **Create New App** → *From scratch* → name it "Squat Coach", pick your
   workspace → **Incoming Webhooks** → toggle **On** → **Add New Webhook to
   Workspace** → choose the channel → copy the `https://hooks.slack.com/…` URL.
3. Share that URL with the pack (treat it like a house key — anyone holding it
   can post to the channel; don't commit it anywhere public).

**Each member:** menu-bar icon → **Settings…** → **Pack** → toggle on, paste the
webhook URL, pick a display name, then **Send a test post** and check the channel.

**Privacy:** sharing is opt-in and sends only your display name, your squat and
set counts, and your streak. Camera frames and pose data never leave your Mac,
sharing on or off.

## How it counts

Joints come from Apple's `VNDetectHumanBodyPoseRequest` (on-device). The signal
is **thigh depth** — how far your hips drop relative to your knees, normalized to
your own standing height so it's independent of camera distance and works from a
head-on laptop webcam (a raw knee *angle* barely changes head-on, which is why an
earlier version over-counted):

```
depth = (hipY − kneeY) / (standing hipY − kneeY)      # 1.0 standing → ~0 deep
```

`SquatCounter.swift` runs a state machine on the smoothed depth:

- **down** when depth `< 0.62` (Normal), back to **standing** when it recovers;
- a rep counts on the **down → up** transition;
- guards that kill miscounts: a hysteresis dead-band, a **dwell** requirement
  (2 sustained frames), a **1 s debounce**, a **dropout reset**, and a per-joint
  **confidence gate**. Only hips + knees need to be in frame — not ankles.

Sensitivity (Easy / Normal / Strict) shifts the `< 0.62` threshold. Verified
against logged squats: 5/5 counted, ~2 s cadence, no doubles.

Run the counter tests: `./build.sh --test`.

## Files

| File | Role |
|---|---|
| `Sources/main.swift` | Menu-bar app delegate, scheduler wiring, notifications, login item |
| `Sources/Scheduler.swift` | Hourly wall-clock-aligned trigger (App-Nap-safe) |
| `Sources/PoseCamera.swift` | AVFoundation capture → Vision pose → thigh-depth signal |
| `Sources/SquatCounter.swift` | The rep-counting state machine (pure, unit-tested) |
| `Sources/WorkoutWindow.swift` | Pop-to-front window, camera preview + skeleton, SwiftUI HUD |
| `Sources/Prefs.swift` | UserDefaults settings + streak store + per-day history |
| `Sources/PackLogic.swift` | Pack message/digest/history logic (pure, unit-tested) |
| `Sources/PackShare.swift` | Fire-and-forget Slack webhook posts (opt-in) |
| `Sources/UpdaterLogic.swift` | Release parsing + version compare (pure, unit-tested) |
| `Sources/Updater.swift` | One-click self-update: download, verify, swap, relaunch |
| `build.sh` / `install.sh` | `swiftc` build + `.app` assembly + ad-hoc sign |

## Credits

Created and maintained by [Brian Cho](https://github.com/brianyoungilcho).
To cite this project, use GitHub's **"Cite this repository"** button (backed by
[CITATION.cff](CITATION.cff)) — and if it kept you moving, a ⭐ helps others find it.

- Built on the [Claude Dash](https://github.com/brianyoungilcho/claude-dash)
  pattern (Swift + `swiftc` + a build script, no Xcode).
- Squat detection uses Apple's on-device
  [Vision](https://developer.apple.com/documentation/vision) framework
  (`VNDetectHumanBodyPoseRequest`) — no third-party libraries, no cloud.
- Built with [Claude Code](https://claude.com/claude-code) (Anthropic).
- Not affiliated with or endorsed by Anthropic or Apple.

MIT licensed.
