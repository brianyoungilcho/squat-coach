#!/usr/bin/env bash
set -euo pipefail

# Squat Coach installer — builds from source into /Applications with the Command
# Line Tools (no Xcode). Re-run after editing to rebuild and relaunch.

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Command Line Tools are required (they provide the Swift compiler)."
  echo "Install with:  xcode-select --install"
  echo "…then re-run ./install.sh"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${SQUAT_COACH_APP:-/Applications/Squat Coach.app}"
"$ROOT/build.sh"

# Restart any running instance so the new build takes over.
osascript -e 'quit app "Squat Coach"' 2>/dev/null || true
sleep 1
pkill -f "Squat Coach.app/Contents/MacOS/SquatCoach" 2>/dev/null && sleep 1 || true
open "$APP"

echo
echo "Squat Coach is running — look for the 🏋️ figure icon in your menu bar."
echo "It will remind you every hour; click the icon → “Do 30 squats now” to try it."
echo "(Registers itself to start at login automatically.)"
