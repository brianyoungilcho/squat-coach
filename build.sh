#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
BIN_NAME="SquatCoach"
APP="${SQUAT_COACH_APP:-/Applications/Squat Coach.app}"
VERSION="${SQUAT_COACH_VERSION:-0.5.0}"
BUILD_NUMBER="${SQUAT_COACH_BUILD_NUMBER:-1}"

if [[ "${1:-}" == "--test" ]]; then
  mkdir -p "$BUILD/checks"
  swiftc \
    -swift-version 5 \
    -parse-as-library \
    -o "$BUILD/checks/logic-tests" \
    "$ROOT/Sources/HistoryLogic.swift" \
    "$ROOT/Sources/ReminderSchedule.swift" \
    "$ROOT/Sources/SocialModels.swift" \
    "$ROOT/Sources/SocialOutbox.swift" \
    "$ROOT/Sources/SquatCounter.swift" \
    "$ROOT/Sources/UpdaterLogic.swift" \
    "$ROOT/Tests/LogicTests.swift"
  exec "$BUILD/checks/logic-tests"
fi

if [[ "$APP" != *.app || "$APP" == "/" ]]; then
  echo "Refusing unsafe app destination: $APP" >&2
  exit 1
fi

STAGE="$BUILD/app-stage"
STAGED_APP="$STAGE/Squat Coach.app"
UNIVERSAL="$BUILD/$BIN_NAME"

rm -rf "$STAGE"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

for arch in arm64 x86_64; do
  scratch="$BUILD/release-$arch"
  triple="${arch}-apple-macosx13.0"
  swift build \
    --package-path "$ROOT" \
    --scratch-path "$scratch" \
    --configuration release \
    --triple "$triple" \
    --product SquatCoach \
    --only-use-versions-from-resolved-file
  bin_path="$(swift build \
    --package-path "$ROOT" \
    --scratch-path "$scratch" \
    --configuration release \
    --triple "$triple" \
    --show-bin-path)"
  cp "$bin_path/$BIN_NAME" "$BUILD/$BIN_NAME-$arch"
  for bundle in "$bin_path"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    ditto "$bundle" "$STAGED_APP/Contents/Resources/$(basename "$bundle")"
  done
done

lipo -create \
  -output "$UNIVERSAL" \
  "$BUILD/$BIN_NAME-arm64" \
  "$BUILD/$BIN_NAME-x86_64"
cp "$UNIVERSAL" "$STAGED_APP/Contents/MacOS/$BIN_NAME"

[[ -f "$ROOT/Assets/AppIcon.icns" ]] &&
  cp "$ROOT/Assets/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
[[ -f "$ROOT/Assets/PrivacyInfo.xcprivacy" ]] &&
  cp "$ROOT/Assets/PrivacyInfo.xcprivacy" "$STAGED_APP/Contents/Resources/PrivacyInfo.xcprivacy"

cat >"$STAGED_APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.healthcare-fitness</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>Squat Coach uses the camera to count your reps. Video is processed entirely on your Mac and is never recorded, saved, or uploaded.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.squatcoach.app.pack-invite</string>
      <key>CFBundleURLSchemes</key><array><string>squatcoach</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$STAGED_APP"

rm -rf "$APP"
ditto "$STAGED_APP" "$APP"

echo "Built $APP (v${VERSION} build ${BUILD_NUMBER}, $(lipo -archs "$APP/Contents/MacOS/$BIN_NAME"))"
