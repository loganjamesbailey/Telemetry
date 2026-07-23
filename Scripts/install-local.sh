#!/bin/bash
# Build Release and install to /Applications.
#
# SMAppService daemons must be tested from a stable path — Xcode's DerivedData
# moves between builds and launchd would keep pointing at a stale binary.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f Config/Local.xcconfig ]; then
    echo "Config/Local.xcconfig missing — copy the template and set your team:" >&2
    echo "  cp Config/Local.xcconfig.template Config/Local.xcconfig" >&2
    exit 1
fi

xcodegen generate
xcodebuild -project Telemetry.xcodeproj -scheme Telemetry -configuration Release \
    -derivedDataPath .build-app build | grep -E "error:|warning:|BUILD" || true

APP=".build-app/Build/Products/Release/Telemetry.app"
[ -d "$APP" ] || { echo "build failed: $APP not found" >&2; exit 1; }

# Verify the daemon embed before installing anything.
test -f "$APP/Contents/MacOS/TelemetryHelper" || { echo "helper missing from bundle" >&2; exit 1; }
test -f "$APP/Contents/Library/LaunchDaemons/com.jamesbailey.telemetry.helper.plist" \
    || { echo "daemon plist missing from bundle" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "codesign verification failed" >&2; exit 1; }

# Quit a running copy before replacing it.
pkill -x Telemetry 2>/dev/null || true
sleep 1

rm -rf /Applications/Telemetry.app
cp -R "$APP" /Applications/Telemetry.app
echo "Installed /Applications/Telemetry.app"
