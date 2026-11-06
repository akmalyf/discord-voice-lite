#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

APP=build/DiscordVoiceLite.app
DAEMON_DIR="${0:A:h:h}/daemon"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
sed "s#__DAEMON_DIR__#$DAEMON_DIR#" Info.plist > "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -framework AppKit -framework Security -framework AVFoundation \
  -o "$APP/Contents/MacOS/DiscordVoiceLite" Sources/*.swift
mkdir -p "$APP/Contents/Resources" build/icon
swift ../packaging/make-icon.swift build/icon
iconutil -c icns build/icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
