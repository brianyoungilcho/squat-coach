# FAQ

**The app is running but there's no icon in the menu bar.**
Two usual causes: (1) On a notched Mac running macOS 26, a status item with no
saved position can get parked in the hidden area left of the notch and never
drawn — Squat Coach seeds a visible slot on first launch, but if it's still
hidden, ⌘-drag it to the right of the notch. (There is no per-app "menu bar"
permission toggle in macOS 26; don't go looking for one.) (2) A crowded menu bar
silently hides items that don't fit — quit something or ⌘-drag icons to make room.

**macOS says the app is damaged / can't be opened (downloaded zip).**
The prebuilt zip is ad-hoc signed, not notarized, and "right-click → Open" no
longer bypasses Gatekeeper on modern macOS. Move the app to `/Applications`
first, then run:
`xattr -dr com.apple.quarantine "/Applications/Squat Coach.app"`.
Homebrew's `--no-quarantine` flag, or building from source (`./install.sh`),
avoids this entirely.

**It's not counting my squats / it counted too many.**
Squat Coach counts how far your **hips drop relative to your knees**, so both
your **hips and knees (thighs) must be in the camera frame** — you don't need
your feet. Step back until the on-screen **depth meter** appears; that means it
can see your thighs. If it counts too eagerly or misses reps, open **Settings →
Sensitivity** (Easy / Normal / Strict) — Strict requires a deeper squat. It
auto-calibrates to your standing height each set, so it adapts to where you sit.

**Does it work with just a laptop webcam?**
Yes — that's the point. It only needs your thighs in view, which a laptop at
normal desk distance can see once you push your chair back a little. It does not
need to see your feet.

**Is my camera being recorded or uploaded?**
No. Pose detection runs entirely on-device via Apple's Vision framework. No
frame is recorded, saved to disk, or sent anywhere — Squat Coach makes no
network requests for video, and needs no account or internet to count squats.
(The only network call in the app is an optional "Check for Updates" that reads
the public GitHub releases list.)

**How do I change how often it reminds me, or how many squats?**
Right-click the menu-bar icon → **Settings…** — set the interval (30 min – 2 hr),
squats per set (10–50), sensitivity, rep sound, and launch-at-login. Or trigger
a set any time with **Do N squats now**.

**Can I trigger a reminder right now from the terminal?**
Yes: `kill -USR1 $(pgrep -f 'Squat Coach.app/Contents/MacOS/SquatCoach')`.

**How do I uninstall it?**
Quit from the menu-bar icon, then delete `/Applications/Squat Coach.app`. To
also remove settings/streak: `defaults delete com.squatcoach.app`. If installed
via Homebrew: `brew uninstall --cask squat-coach`.

**Why isn't it notarized?**
It's a small open-source personal tool; notarization needs a paid Apple Developer
account. Building from source (`./install.sh`) sidesteps Gatekeeper completely,
and the Homebrew cask clears quarantine for you.
