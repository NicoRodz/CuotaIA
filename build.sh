#!/bin/bash
set -euo pipefail

APP="CuotaIA.app"
MACOS="$APP/Contents/MacOS"

# Elige el swiftc más nuevo entre los toolchains instalados. Un Xcode viejo junto a unos Command
# Line Tools recientes deja a `xcrun` apuntando al compilador antiguo, que no conoce las API de
# macOS 26 (NSGlassEffectView) y hace fallar la compilación con "cannot find in scope".
pick_swiftc() {
    local best="" best_version=""
    for candidate in \
        /Library/Developer/CommandLineTools/usr/bin/swiftc \
        /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
        "$(command -v swiftc || true)"
    do
        [ -x "$candidate" ] || continue
        local version
        version=$("$candidate" --version 2>/dev/null | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)
        [ -n "$version" ] || continue
        if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -1)" = "$version" ]; then
            best="$candidate"
            best_version="$version"
        fi
    done
    [ -n "$best" ] || { echo "No se encontró swiftc. Instala: xcode-select --install" >&2; exit 1; }
    echo "$best"
}

SWIFTC=$(pick_swiftc)
SDK=$("$(dirname "$SWIFTC")/../../usr/bin/xcrun" --show-sdk-path 2>/dev/null || xcrun --show-sdk-path)

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

echo "swiftc: $SWIFTC"
echo "sdk:    $SDK"
"$SWIFTC" -target arm64-apple-macosx11.0 -sdk "$SDK" -module-cache-path build/module-cache \
    -framework AppKit -framework UserNotifications Sources/*.swift -o "$MACOS/CuotaIA"
codesign -s - --deep "$APP"
