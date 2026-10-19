#!/bin/bash
# Bouwt Claude Usage.app en installeert hem in ~/Applications.
#   ./build.sh           bouwen + installeren + starten
#   ./build.sh --login   idem, en automatisch starten bij inloggen (LaunchAgent)
#   ./build.sh --unlogin LaunchAgent weer verwijderen
#   ./build.sh --package alleen bouwen en inpakken als build/ClaudeUsage-macos.zip (voor delen/CI)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Claude Usage.app"
LABEL="nl.broekhuis.claude-usage"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "${1:-}" == "--unlogin" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"
  echo "Start bij inloggen uitgezet."
  exit 0
fi

BUILD="$HERE/build/Claude Usage.app"
rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
# Universeel: draait op Apple Silicon én Intel.
for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos13.0" -o "$HERE/build/ClaudeUsage-$ARCH" "$HERE/main.swift" \
    -framework AppKit -framework SwiftUI
done
lipo -create -output "$BUILD/Contents/MacOS/ClaudeUsage" "$HERE/build/ClaudeUsage-arm64" "$HERE/build/ClaudeUsage-x86_64"
rm -f "$HERE/build/ClaudeUsage-arm64" "$HERE/build/ClaudeUsage-x86_64"

# Icoon opnieuw genereren als het ontbreekt of make_icon.swift nieuwer is.
if [[ ! -f "$HERE/AppIcon.icns" || "$HERE/make_icon.swift" -nt "$HERE/AppIcon.icns" ]]; then
  rm -rf "$HERE/build/AppIcon.iconset"
  swift "$HERE/make_icon.swift" "$HERE/build/AppIcon.iconset" >/dev/null
  iconutil -c icns "$HERE/build/AppIcon.iconset" -o "$HERE/AppIcon.icns"
fi
cp "$HERE/AppIcon.icns" "$BUILD/Contents/Resources/AppIcon.icns"

cat > "$BUILD/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUILD" >/dev/null

if [[ "${1:-}" == "--package" ]]; then
  ZIP="$HERE/build/ClaudeUsage-macos.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$BUILD" "$ZIP"
  echo "Ingepakt: $ZIP"
  exit 0
fi

pkill -x ClaudeUsage 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$BUILD" "$APP"

if [[ "${1:-}" == "--login" ]]; then
  mkdir -p "$(dirname "$AGENT")"
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT"
  echo "Start bij inloggen aangezet."
else
  open "$APP"
fi
echo "Geïnstalleerd: $APP"
