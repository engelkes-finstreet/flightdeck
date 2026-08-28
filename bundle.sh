#!/bin/bash
# Assembles the SPM binary into a real .app bundle. A bundle (not a bare
# executable) is what gives Flightdeck a Dock presence, window restoration,
# and a bundle identifier for UserNotifications later.
set -euo pipefail

CONFIG="${1:-release}"
APP="dist/Flightdeck.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Flightdeck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Flightdeck"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Flightdeck</string>
  <key>CFBundleDisplayName</key><string>Flightdeck</string>
  <key>CFBundleIdentifier</key><string>codes.flightdeck.app</string>
  <key>CFBundleExecutable</key><string>Flightdeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: ad-hoc signing skipped"
echo "built $APP"
