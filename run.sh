#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
APP="$(pwd)/.build/ClipHarbor.app"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/ClipHarbor" "$APP/Contents/MacOS/ClipHarbor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClipHarbor</string>
<key>CFBundleIdentifier</key><string>com.clipharbor.app</string>
<key>CFBundleName</key><string>ClipHarbor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
open "$APP"
