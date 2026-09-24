#!/bin/bash
# Builds ClaudeUsage.app into ./build and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeUsage.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS"

swiftc -O -framework Cocoa -lsqlite3 -o "$APP/Contents/MacOS/ClaudeUsage" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeUsage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>com.sakthi.claude-usage-bar</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu-bar-only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps the Keychain ACL stable across rebuilds, so the
# "always allow" grant for Claude Code-credentials is not re-prompted.
codesign --force --sign - "$APP" 2>/dev/null || true

rm -rf /Applications/ClaudeUsage.app
cp -R "$APP" /Applications/
echo "Installed /Applications/ClaudeUsage.app"
