#!/bin/bash
set -euo pipefail

APP="CuotaIA.app"
MACOS="$APP/Contents/MacOS"
mkdir -p "$MACOS"
mkdir -p build/module-cache
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CuotaIA</string>
<key>CFBundleIdentifier</key><string>com.nicorodz.cuotaia</string>
<key>CFBundleName</key><string>CuotaIA</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>11.0</string>
</dict></plist>
PLIST
swiftc -target arm64-apple-macosx11.0 -module-cache-path build/module-cache -framework AppKit -framework UserNotifications Sources/*.swift -o "$MACOS/CuotaIA"
codesign -s - --deep "$APP"
