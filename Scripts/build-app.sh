#!/usr/bin/env bash
# Builds Overbright.app from the Swift package. Requires the Xcode command line tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Overbright.app"
BUNDLE_ID="app.overbright.Overbright"
VERSION="1.0.0"

cd "$ROOT"
swift build -c release --disable-sandbox

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$(swift build -c release --show-bin-path)/Overbright" "$APP/Contents/MacOS/Overbright"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Overbright</string>
    <key>CFBundleDisplayName</key><string>Overbright</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Overbright</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough to launch locally; replace with a Developer ID identity
# (and notarise) before distributing to anyone else.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Run it with: open '$APP'"
