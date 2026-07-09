#!/usr/bin/env bash
set -euo pipefail

# Build Squat Coach into /Applications/Squat Coach.app using ONLY the Command
# Line Tools (swiftc) — no Xcode. Mirrors the Claude Dash build pattern.
#   ./build.sh          build a UNIVERSAL (arm64 + x86_64) app + install it
#   ./build.sh --test   compile & run the SquatCounter unit tests, then exit

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
BIN_NAME="SquatCoach"
APP="${SQUAT_COACH_APP:-/Applications/Squat Coach.app}"
VERSION="${SQUAT_COACH_VERSION:-0.3.0}"
HOST_ARCH="$(uname -m)"   # arm64 on Apple Silicon — used for the test build only

FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework AVFoundation -framework Vision
            -framework CoreMedia -framework CoreVideo -framework QuartzCore
            -framework UserNotifications -framework ServiceManagement)

if [[ "${1:-}" == "--test" ]]; then
  echo "==> Building + running SquatCounter tests"
  mkdir -p "$BUILD/counter-tests" "$BUILD/pack-tests"
  # Top-level test code is only allowed in a file named main.swift, so stage it.
  cp "$ROOT/Tests/SquatCounterTests.swift" "$BUILD/counter-tests/main.swift"
  swiftc -swift-version 5 -target "${HOST_ARCH}-apple-macos13.0" \
    -o "$BUILD/squattests" \
    "$ROOT/Sources/SquatCounter.swift" "$BUILD/counter-tests/main.swift"
  "$BUILD/squattests"

  echo "==> Building + running PackLogic tests"
  cp "$ROOT/Tests/PackLogicTests.swift" "$BUILD/pack-tests/main.swift"
  swiftc -swift-version 5 -target "${HOST_ARCH}-apple-macos13.0" \
    -o "$BUILD/packtests" \
    "$ROOT/Sources/PackLogic.swift" "$BUILD/pack-tests/main.swift"
  "$BUILD/packtests"

  echo "==> Building + running UpdaterLogic tests"
  mkdir -p "$BUILD/updater-tests"
  cp "$ROOT/Tests/UpdaterLogicTests.swift" "$BUILD/updater-tests/main.swift"
  swiftc -swift-version 5 -target "${HOST_ARCH}-apple-macos13.0" \
    -o "$BUILD/updatertests" \
    "$ROOT/Sources/UpdaterLogic.swift" "$BUILD/updater-tests/main.swift"
  "$BUILD/updatertests"
  exit $?
fi

echo "==> Compiling (arm64 + x86_64, macOS 13+)"
rm -rf "$BUILD"; mkdir -p "$BUILD"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "${arch}-apple-macos13.0" \
    -o "$BUILD/$BIN_NAME-$arch" \
    "$ROOT"/Sources/*.swift \
    "${FRAMEWORKS[@]}"
done
lipo -create -output "$BUILD/$BIN_NAME" "$BUILD/$BIN_NAME-arm64" "$BUILD/$BIN_NAME-x86_64"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
[ -f "$ROOT/Assets/AppIcon.icns" ] && cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Squat Coach</string>
  <key>CFBundleDisplayName</key><string>Squat Coach</string>
  <key>CFBundleIdentifier</key><string>com.squatcoach.app</string>
  <key>CFBundleExecutable</key><string>${BIN_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.healthcare-fitness</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Squat Coach uses the camera to watch your squats and count your reps. Video is processed entirely on your Mac and is never recorded, saved, or sent anywhere.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP (v${VERSION}, $(lipo -archs "$APP/Contents/MacOS/$BIN_NAME"))"
